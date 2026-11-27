// Controller remapping (included by rawmouse.m).
//
// Two halves in two Wine processes of the same environment:
//  • The controller driver (winedevice.exe, where Wine's winebus reads controllers through SDL): Wine looks up
//    SDL's functions with dlsym; ours are handed back for SDL_WaitEventTimeout and SDL_GameControllerOpen, so
//    every controller event goes through the mapping engine (padengine.c) on its way to the game. Remapped
//    controller buttons and sticks go back into the event stream; keys and mouse go to the game's process.
//  • The game (the Wine program whose window is in front): when it comes to the front it writes pad-active
//    (its process id and the profile to use) next to this library, and takes keys and mouse from a socket.
// No profile, or no game in front: controllers pass through unchanged.
#include "padengine.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <ctype.h>

// MARK: Minimal SDL2 types (only what Wine's driver loop uses)
typedef struct { uint32_t type, timestamp; int32_t which; uint8_t button, state, p1, p2; } nok_sdl_cbutton;
typedef struct { uint32_t type, timestamp; int32_t which; uint8_t axis, p1, p2, p3; int16_t value; uint16_t p4; } nok_sdl_caxis;
typedef struct { uint32_t type, timestamp; int32_t which; int32_t sensor; float data[3]; } nok_sdl_csensor;
typedef struct { uint32_t type, timestamp; int32_t which; uint8_t hat, value, p1, p2; } nok_sdl_jhat;
typedef struct { uint32_t type, timestamp; int32_t which; int32_t touchpad, finger; float x, y, pressure; } nok_sdl_ctouch;
// Joystick events have the same layout as the controller's: axis like caxis, buttons like cbutton.
typedef union { uint32_t type; nok_sdl_cbutton cbutton; nok_sdl_caxis caxis; nok_sdl_csensor csensor; nok_sdl_jhat jhat; nok_sdl_ctouch ctouch; uint8_t pad[56]; } nok_sdl_event;
enum { NOK_SDL_CAXIS = 0x650, NOK_SDL_CBDOWN = 0x651, NOK_SDL_CBUP = 0x652, NOK_SDL_CADDED = 0x653, NOK_SDL_CREMOVED = 0x654,
       NOK_SDL_CSENSOR = 0x659, NOK_SDL_SENSOR_GYRO = 2, NOK_SDL_SENSOR_ACCEL = 1,
       NOK_SDL_CTOUCHDOWN = 0x656, NOK_SDL_CTOUCHMOTION = 0x657, NOK_SDL_CTOUCHUP = 0x658,
       NOK_SDL_JAXIS = 0x600, NOK_SDL_JHAT = 0x602, NOK_SDL_JBDOWN = 0x603, NOK_SDL_JBUP = 0x604, NOK_SDL_JADDED = 0x605, NOK_SDL_JREMOVED = 0x606 };

// Messages from the driver to the game process.
enum { PADMSG_KEY = 1, PADMSG_MOUSE_BUTTON, PADMSG_MOUSE_MOVE, PADMSG_WHEEL, PADMSG_RELEASE };
typedef struct { uint8_t kind, down; int16_t code; int32_t dx, dy; } padmsg;

static char pad_state_dir[PATH_MAX];
// The sockets live in a folder only this user can enter: /tmp itself is shared by every account on the Mac, so
// another account could have taken a socket's name there first. The folder must be a real folder, ours, and
// closed to everyone else, or no socket is made (Nokcandu applies the same test before sending).
static bool pad_socket_dir(char *out, size_t n) {
    snprintf(out, n, "/tmp/nokcandu-%u", getuid());
    mkdir(out, 0700);
    struct stat st;
    return lstat(out, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == getuid() && (st.st_mode & 077) == 0;
}
static void pad_named_socket(const char *kind, pid_t pid, char *out, size_t n) {
    char dir[64];
    if (pad_socket_dir(dir, sizeof dir)) snprintf(out, n, "%s/nokcandu-%s-%u-%d.sock", dir, kind, getuid(), (int)pid);
    else if (n) out[0] = 0;
}
static void pad_socket_path(pid_t pid, char *out, size_t n) { pad_named_socket("pad", pid, out, n); }
static double pad_now(void) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// MARK: - Driver half (winedevice.exe)

static bool pad_bus;                                   // this process hosts Wine's controller driver
static int (*real_wait)(nok_sdl_event *, int);
static void *(*real_open)(int);
static int (*real_sensor)(void *, int, int);
static int32_t (*real_instance)(void *);

static int (*real_num_joysticks)(void);
static int32_t (*real_device_instance)(int);
static uint16_t (*real_device_vendor)(int), (*real_device_product)(int);

#define PAD_MAX 8
// One engine per controller. With a profile that combines devices, one of them is the main controller (main):
// the devices' inputs go into its engine, and what they do comes out as that controller. Until a controller is
// there the main engine waits with which = -1 (keys and mouse still work; controller outputs go nowhere).
static struct { int32_t which; pe_engine *e; bool used, main; int player; } pads[PAD_MAX];
// Local co-op: controllers in the order they were first seen (player 1 first), and what each later player gets from
// the compiled map ("player N asis | same | begin … end"): 0 the controller as it is (no engine), 1 player 1's
// profile, 2 a profile of its own (pad_player_text). Maps from before co-op have no player lines: everyone had it.
static int32_t pad_seen[PAD_MAX]; static int pad_seen_n;
static int pad_player_kind[9]; static char *pad_player_text[9];
static bool pad_has_devices;
static int32_t slot_sources[PE_MAX_DEVICES + 1];
static bool slot_source_valid[PE_MAX_DEVICES + 1];
static struct { int32_t which; int slot; } slot_cache[16]; static int slot_cached;
static char pad_profile_text[65536];
static char pad_profile_path[PATH_MAX];
static pid_t pad_game_pid;
static time_t pad_active_mtime, pad_profile_mtime; static long pad_active_ns, pad_profile_ns;
static double pad_last_check;
static nok_sdl_event pad_queue[256]; static int pad_qh, pad_qt;
static int pad_sock = -1;
static unsigned long st_buttons, st_axes, st_gyro, st_ticks, st_mouse_msgs; static long st_mouse_x, st_mouse_y;
static float st_gx, st_gy, st_gz; static double st_last_write, st_max_gap, st_last_wait;
static bool st_sensor_ok;

static void pad_push(nok_sdl_event ev) {
    int next = (pad_qt + 1) % 256;
    if (next == pad_qh) return;
    pad_queue[pad_qt] = ev; pad_qt = next;
}
static bool pad_pop(nok_sdl_event *ev) {
    if (pad_qh == pad_qt) return false;
    *ev = pad_queue[pad_qh]; pad_qh = (pad_qh + 1) % 256; return true;
}
static void pad_send(padmsg m) {
    if (pad_game_pid <= 0) return;
    if (pad_sock < 0) pad_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (pad_sock < 0) return;
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    pad_socket_path(pad_game_pid, a.sun_path, sizeof a.sun_path);
    if (!a.sun_path[0]) return;
    sendto(pad_sock, &m, sizeof m, MSG_DONTWAIT, (struct sockaddr *)&a, sizeof a);
}
static int32_t pad_which_of(void *ctx) { int i = (int)(intptr_t)ctx; return i >= 0 && i < PAD_MAX && pads[i].used ? pads[i].which : -1; }
static void sink_pad_button(void *ctx, int b, bool down) {
    nok_sdl_event ev = {0};
    int32_t which = pad_which_of(ctx); if (which < 0) return;
    ev.cbutton.type = down ? NOK_SDL_CBDOWN : NOK_SDL_CBUP; ev.cbutton.which = which;
    ev.cbutton.button = (uint8_t)b; ev.cbutton.state = down; pad_push(ev);
}
static void sink_pad_axis(void *ctx, int a, int v) {
    nok_sdl_event ev = {0};
    int32_t which = pad_which_of(ctx); if (which < 0) return;
    ev.caxis.type = NOK_SDL_CAXIS; ev.caxis.which = which; ev.caxis.axis = (uint8_t)a; ev.caxis.value = (int16_t)v; pad_push(ev);
}
// Keys and mouse come from Nokcandu itself (it runs the same profile for the game in front); here the profile only
// decides what the game sees as the controller — remapped buttons, and nothing for buttons set to keys or mouse.
static void sink_key(void *ctx, int k, bool d) { (void)ctx; (void)k; (void)d; }
static void sink_mouse_button(void *ctx, int b, bool d) { (void)ctx; (void)b; (void)d; }
static void sink_mouse_move(void *ctx, int x, int y) { (void)ctx; st_mouse_msgs++; st_mouse_x += x; st_mouse_y += y; }
// What the driver half has seen (pad-status next to this library), every two seconds while a profile is in use.
static void pad_status(double now) {
    if (!pad_profile_text[0] || now - st_last_write < 2) return;
    double span = st_last_write > 0 ? now - st_last_write : 2;
    st_last_write = now;
    char path[PATH_MAX]; snprintf(path, sizeof path, "%s/pad-status", pad_state_dir);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "driver %.1fs: buttons %lu axes %lu gyro %lu (sensor %s, last %.2f %.2f %.2f rad/s) ticks %lu longest wait %.0f ms; mouse %lu moves, total %ld,%ld; game pid %d\n",
            span, st_buttons, st_axes, st_gyro, st_sensor_ok ? "on" : "not turned on", st_gx, st_gy, st_gz, st_ticks, st_max_gap * 1000,
            st_mouse_msgs, st_mouse_x, st_mouse_y, (int)pad_game_pid);
    fclose(f);
    st_buttons = st_axes = st_gyro = st_ticks = st_mouse_msgs = 0; st_mouse_x = st_mouse_y = 0; st_max_gap = 0;
}
static void sink_wheel(void *ctx, int n) { (void)ctx; (void)n; }

static void pad_parse_players(void) {
    for (int n = 0; n < 9; n++) { free(pad_player_text[n]); pad_player_text[n] = NULL; pad_player_kind[n] = 0; }
    const char *t = pad_profile_text;
    if (!strstr(t, "\nplayer ")) { for (int n = 2; n < 9; n++) pad_player_kind[n] = 1; return; }
    for (int n = 2; n < 9; n++) {
        char key[40], end[40];
        snprintf(key, sizeof key, "\nplayer %d same\n", n);
        if (strstr(t, key)) { pad_player_kind[n] = 1; continue; }
        snprintf(key, sizeof key, "\nplayer %d begin\n", n); snprintf(end, sizeof end, "\nplayer %d end\n", n);
        const char *b = strstr(t, key);
        const char *e = b ? strstr(b + strlen(key), end + 1) : NULL;
        if (b && e) { b += strlen(key); pad_player_text[n] = strndup(b, (size_t)(e - b)); pad_player_kind[n] = 2; }
    }
}
// Which controller is which (Nokcandu's Controllers panel): each opened controller's key and the player it was set
// to (0: Auto), matched against controller-players, which Nokcandu writes. Matched by the connection itself (the
// registry id in SDL's device path), then the serial, then the model and its place among identical ones.
static void *(*real_joystick)(void *);
static const char *(*id_path)(void *), *(*id_serial)(void *);
static uint16_t (*id_vendor)(void *), (*id_product)(void *);
#define PAD_IDS 16
static struct { int32_t which; unsigned long long registry; int vid, pid, nth; char serial[64]; char key[96]; int seat; char *text; bool text_known; } pad_ids[PAD_IDS];
static int pad_ids_n;
static char pad_players_text[16384];
static time_t pad_players_mtime; static long pad_players_ns;

static bool pad_changed(const char *path, time_t *mt, long *ns);
static void pad_report_players(void);
static bool pad_is_fed_device(int32_t which);
static void pad_norm_serial(const char *in, char *out, size_t n) {
    size_t k = 0;
    for (const char *c = in ? in : ""; *c && k + 1 < n; c++) if (isalnum((unsigned char)*c) && (unsigned char)*c < 128) out[k++] = (char)tolower((unsigned char)*c);
    out[k] = 0;
    bool same = true, zeros = true;
    for (size_t i = 1; i < k; i++) if (out[i] != out[0]) same = false;
    for (size_t i = 0; i + 1 < k; i++) if (out[i] != '0') zeros = false;
    if (k < 6 || same || zeros) out[0] = 0;
}
static int pad_id_index(int32_t which) { for (int i = 0; i < pad_ids_n; i++) if (pad_ids[i].which == which) return i; return -1; }
static void pad_match(int i) {
    pad_ids[i].key[0] = 0; pad_ids[i].seat = 0;
    char key[96]; int best = 0;
    for (const char *line = pad_players_text; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
        unsigned long long reg; int vid, pid, nth, seat; char serial[64];
        if (sscanf(line, "c %llu %d %d %63s %d %d %95s", &reg, &vid, &pid, serial, &nth, &seat, key) != 7) continue;
        int score = reg && reg == pad_ids[i].registry ? 3
            : vid == pad_ids[i].vid && pid == pad_ids[i].pid && pad_ids[i].serial[0] && !strcmp(serial, pad_ids[i].serial) ? 2
            : vid == pad_ids[i].vid && pid == pad_ids[i].pid && nth == pad_ids[i].nth ? 1 : 0;
        if (score > best) { best = score; strlcpy(pad_ids[i].key, key, sizeof pad_ids[i].key); pad_ids[i].seat = seat < 0 ? 0 : seat > 8 ? 8 : seat; }
    }
}
static void pad_read_players(bool force) {
    const char *home = getenv("HOME");
    if (!home) return;
    char path[PATH_MAX]; snprintf(path, sizeof path, "%s/Library/Application Support/Nokcandu/controller-players", home);
    if (!pad_changed(path, &pad_players_mtime, &pad_players_ns) && !force) return;
    pad_players_text[0] = 0;
    FILE *f = fopen(path, "r");
    if (f) { size_t n = fread(pad_players_text, 1, sizeof pad_players_text - 1, f); pad_players_text[n] = 0; fclose(f); }
    if (strncmp(pad_players_text, "nokplayers ", 11)) pad_players_text[0] = 0;
    for (int i = 0; i < pad_ids_n; i++) pad_match(i);
}
/// Notes a controller: who it is, from SDL. Called the first time Wine asks about it (its maker, model or name,
/// as it creates the Windows device) and when it's opened: Wine builds differ in which of those happen.
static void pad_identify_joystick(void *j) {
    if (!j || !real_instance) return;
    int32_t which = real_instance(j);
    if (pad_id_index(which) >= 0) return;
    if (pad_ids_n >= PAD_IDS) return;
    int i = pad_ids_n++; memset(&pad_ids[i], 0, sizeof pad_ids[i]); pad_ids[i].which = which;
    const char *p = id_path ? id_path(j) : NULL;
    const char *dev = p ? strstr(p, "DevSrvsID:") : NULL;
    pad_ids[i].registry = dev ? strtoull(dev + 10, NULL, 10) : 0;
    pad_ids[i].vid = id_vendor ? id_vendor(j) : 0; pad_ids[i].pid = id_product ? id_product(j) : 0;
    pad_norm_serial(id_serial ? id_serial(j) : NULL, pad_ids[i].serial, sizeof pad_ids[i].serial);
    pad_ids[i].nth = 0;
    for (int k = 0; k < pad_ids_n; k++) if (k != i && pad_ids[k].vid == pad_ids[i].vid && pad_ids[k].pid == pad_ids[i].pid && pad_ids[k].which < which) pad_ids[i].nth++;
    pad_read_players(true);
    fprintf(stderr, "nokcandu: controller %04x:%04x (registry %llu, serial %s) is %s, %s\n", pad_ids[i].vid, pad_ids[i].pid, pad_ids[i].registry,
            pad_ids[i].serial[0] ? "known" : "none", pad_ids[i].key[0] ? pad_ids[i].key : "not in Nokcandu's list", pad_ids[i].seat ? "set to a player" : "Auto");
    pad_report_players();
}
static void pad_identify(void *controller) {
    if (controller && real_joystick) pad_identify_joystick(real_joystick(controller));
}
static void pad_forget_identity(int32_t which) {
    int i = pad_id_index(which);
    if (i < 0) return;
    free(pad_ids[i].text);
    pad_ids[i] = pad_ids[--pad_ids_n];
}
static int pad_seat_of(int32_t which) { int i = pad_id_index(which); return i >= 0 ? pad_ids[i].seat : 0; }
/// The player a controller is (1 first). One set to a player in Nokcandu is that player; the rest take the lowest
/// players nobody chose, in the order they were first seen (with nothing set: their place in that order).
static int (*real_is_gc)(int);
static void pad_see(int32_t which) {
    for (int i = 0; i < pad_seen_n; i++) if (pad_seen[i] == which) return;
    if (pad_seen_n < PAD_MAX) pad_seen[pad_seen_n++] = which;
}
static int pad_player_of(int32_t which) {
    // Every game controller connected counts, in SDL's order, not only those Wine has asked about yet: Wine
    // creates one device at a time, and the first must not take player 1 from the Steam Controller a profile reads.
    if (real_num_joysticks && real_device_instance && real_is_gc) {
        int n = real_num_joysticks();
        for (int i = 0; i < n; i++) if (real_is_gc(i)) pad_see(real_device_instance(i));
    }
    pad_see(which);
    int seat = pad_seat_of(which);
    if (seat > 0) return seat;
    bool taken[PAD_MAX + 2] = { false };
    for (int i = 0; i < pad_seen_n; i++) { int s = pad_seat_of(pad_seen[i]); if (s > 0 && s <= PAD_MAX) taken[s] = true; }
    int next = 1;
    // A profile that reads the Steam Controller itself is that controller's: under Auto it's player 1, whichever
    // controller Wine happened to notice first.
    for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < pad_seen_n; i++) {
            if (pad_seat_of(pad_seen[i]) > 0 || pad_is_fed_device(pad_seen[i]) != (pass == 0)) continue;
            while (next <= PAD_MAX && taken[next]) next++;
            if (pad_seen[i] == which) return next > PAD_MAX ? PAD_MAX : next;
            taken[next < PAD_MAX + 2 ? next : PAD_MAX + 1] = true;
        }
    return PAD_MAX;
}
static void pad_forget_player(int32_t which) {
    for (int i = 0; i < pad_seen_n; i++) if (pad_seen[i] == which) {
        memmove(&pad_seen[i], &pad_seen[i + 1], (size_t)(pad_seen_n - i - 1) * sizeof pad_seen[0]); pad_seen_n--; return;
    }
}
/// Tells Nokcandu which player each controller became (pad-players-seen: "<key> <player>" lines).
static void pad_report_players(void) {
    if (!pad_bus || !pad_state_dir[0]) return;
    char path[PATH_MAX], tmp[PATH_MAX];
    snprintf(path, sizeof path, "%s/pad-players-seen", pad_state_dir); snprintf(tmp, sizeof tmp, "%s.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "pid %d\n", (int)getpid());
    for (int i = 0; i < pad_ids_n; i++) if (pad_ids[i].key[0]) fprintf(f, "%s %d\n", pad_ids[i].key, pad_player_of(pad_ids[i].which));
    fclose(f); rename(tmp, path);
}
/// A controller's own profile in this game ("controller <key> begin" … "end"), or NULL.
static const char *pad_own_text(int32_t which) {
    int i = pad_id_index(which);
    if (i < 0 || !pad_ids[i].key[0] || !pad_profile_text[0]) return NULL;
    if (!pad_ids[i].text_known) {
        pad_ids[i].text_known = true;
        char b[128], e[128];
        snprintf(b, sizeof b, "\ncontroller %s begin\n", pad_ids[i].key); snprintf(e, sizeof e, "\ncontroller %s end\n", pad_ids[i].key);
        const char *s = strstr(pad_profile_text, b), *t = s ? strstr(s + strlen(b) - 1, e) : NULL;
        if (s && t) pad_ids[i].text = strndup(s + strlen(b), (size_t)(t + 1 - (s + strlen(b))));
    }
    return pad_ids[i].text;
}
static void pad_forget_own_texts(void) { for (int i = 0; i < pad_ids_n; i++) { free(pad_ids[i].text); pad_ids[i].text = NULL; pad_ids[i].text_known = false; } }
/// The compiled profile a player's engine runs (NULL: the controller as it is).
static const char *pad_text_for_player(int player) {
    if (player <= 1) return pad_profile_text;
    int n = player > 8 ? 8 : player;
    return pad_player_kind[n] == 1 ? pad_profile_text : pad_player_kind[n] == 2 ? pad_player_text[n] : NULL;
}
/// What a controller's engine runs: its own profile in this game, or its player's.
static const char *pad_text_for(int32_t which, int player) {
    const char *own = which >= 0 ? pad_own_text(which) : NULL;
    return own ? own : pad_text_for_player(player);
}
static pe_engine *pad_new_engine(int32_t which, bool main) {
    int player = which >= 0 ? pad_player_of(which) : 1;
    const char *text = pad_text_for(which, player);
    if (!text) return NULL;
    for (int i = 0; i < PAD_MAX; i++) if (!pads[i].used) {
        pe_sink s = { (void *)(intptr_t)i, sink_pad_button, sink_pad_axis, sink_key, sink_mouse_button, sink_mouse_move, sink_wheel, NULL };
        pads[i].e = pe_create(text, s);
        if (!pads[i].e) return NULL;
        pads[i].which = which; pads[i].used = true; pads[i].main = main; pads[i].player = player;
        return pads[i].e;
    }
    return NULL;
}
static pe_engine *pad_engine_for(int32_t which, bool create) {
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used && pads[i].which == which) return pads[i].e;
    if (!create || !pad_profile_text[0]) return NULL;
    // A later player whose controller stays as it is: no engine, its events pass through.
    if (pad_player_of(which) > 1 && !pad_text_for(which, pad_player_of(which))) return NULL;
    // Controllers set to the same player in Nokcandu drive it together: one engine, the first controller's output.
    if (pad_seat_of(which) > 0 && !pad_own_text(which))
        for (int i = 0; i < PAD_MAX; i++)
            if (pads[i].used && pads[i].which >= 0 && pads[i].player == pad_player_of(which) && pad_seat_of(pads[i].which) > 0 && !pad_own_text(pads[i].which))
                return pads[i].e;
    // The devices' engine was waiting for a controller: this one becomes the main controller.
    if (pad_player_of(which) == 1)
        for (int i = 0; i < PAD_MAX; i++) if (pads[i].used && pads[i].main && pads[i].which < 0) { pads[i].which = which; return pads[i].e; }
    bool main = pad_has_devices;
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used && pads[i].main) main = false;
    return pad_new_engine(which, main);
}
// The engine the devices feed (the main controller's).
static pe_engine *pad_main_engine(void) {
    if (!pad_profile_text[0]) return NULL;
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used && pads[i].main) return pads[i].e;
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used) { pads[i].main = true; return pads[i].e; }
    return pad_new_engine(-1, true);
}
// Which of the profile's devices an SDL joystick is (0: none): its maker and model codes, and with several
// identical ones, its place among them (in the order they were connected).
static int pad_slot_for(int32_t which) {
    if (!pad_has_devices) return 0;
    for (int i = 0; i < slot_cached; i++) if (slot_cache[i].which == which) return slot_cache[i].slot;
    int slot = 0;
    pe_engine *e = pad_main_engine();
    if (e && real_num_joysticks && real_device_instance && real_device_vendor && real_device_product) {
        int n = real_num_joysticks(), vid = -1, pid = -1;
        for (int i = 0; i < n; i++) if (real_device_instance(i) == which) { vid = real_device_vendor(i); pid = real_device_product(i); }
        int nth = 0;
        for (int i = 0; i < n; i++) if (real_device_vendor(i) == vid && real_device_product(i) == pid && real_device_instance(i) < which) nth++;
        for (int d = 1; d <= pe_device_count(e) && vid >= 0; d++) {
            int v, p, k; bool gp, joined;
            if (pe_device_info(e, d, &v, &p, &k, &gp, &joined) && v == vid && p == pid && k == nth) { slot = d; break; }
        }
        if (slot) fprintf(stderr, "nokcandu: device %04x:%04x #%d is the profile's device %d\n", vid, pid, nth + 1, slot);
    }
    if (slot) {
        if (slot_source_valid[slot] && slot_sources[slot] != which && e) pe_release_device(e, slot, pad_now());
        slot_sources[slot] = which; slot_source_valid[slot] = true;
    }
    if (slot_cached < 16) { slot_cache[slot_cached].which = which; slot_cache[slot_cached].slot = slot; slot_cached++; }
    return slot;
}
static bool pad_slot_gamepad(int slot) {
    bool gp = false; pe_engine *e = pad_main_engine();
    return e && pe_device_info(e, slot, NULL, NULL, NULL, &gp, NULL) && gp;
}
static void pad_drop_engines(void) {
    double now = pad_now();
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used) {
        pe_release_all(pads[i].e, now); pe_destroy(pads[i].e); pads[i].used = false; pads[i].main = false;
    }
    slot_cached = 0; memset(slot_source_valid, 0, sizeof slot_source_valid);
    pad_send((padmsg){ PADMSG_RELEASE, 0, 0, 0, 0 });
}
static bool pad_changed(const char *path, time_t *mt, long *ns) {
    struct stat st;
    if (stat(path, &st) != 0) { bool was = *mt != 0; *mt = 0; *ns = 0; return was; }
    if (st.st_mtimespec.tv_sec == *mt && st.st_mtimespec.tv_nsec == *ns) return false;
    *mt = st.st_mtimespec.tv_sec; *ns = st.st_mtimespec.tv_nsec; return true;
}
// Nokcandu touches this to calibrate the gyro (its keyboard shortcut).
static time_t pad_cal_mtime; static long pad_cal_ns; static bool pad_cal_seen;
static void pad_check_calibrate(double now) {
    char path[PATH_MAX]; const char *home = getenv("HOME");
    if (!home) return;
    snprintf(path, sizeof path, "%s/Library/Application Support/Nokcandu/controller-calibrate", home);
    bool changed = pad_changed(path, &pad_cal_mtime, &pad_cal_ns);
    if (changed && pad_cal_seen && pad_cal_mtime) for (int i = 0; i < PAD_MAX; i++) if (pads[i].used) pe_calibrate(pads[i].e, now);
    pad_cal_seen = true;
}
// MARK: Fed by Nokcandu
// A profile that reads the controller itself (the original Steam Controller read directly, "source steam" in its
// map) runs in Nokcandu, which sees everything the controller has (trackpads, grips, motion). Its controller output
// comes here over a socket and becomes the controller the game sees; that controller's raw input from SDL is
// dropped, so the game never gets the raw controller, mapped its own way, alongside the profile's.
typedef struct { uint8_t kind, code; int16_t value; } padfeed;   // kind 1 button, 2 axis
static bool pad_feed_on;
static int pad_feed_fd = -1;
static int32_t pad_feed_which = -1;
static void pad_feed_open(bool on) {
    char info[PATH_MAX]; snprintf(info, sizeof info, "%s/pad-feed", pad_state_dir);
    if (on == (pad_feed_fd >= 0)) { pad_feed_on = on; return; }
    pad_feed_on = on;
    char path[104]; pad_named_socket("padfeed", getpid(), path, sizeof path);
    if (!path[0]) return;
    if (!on) { close(pad_feed_fd); pad_feed_fd = -1; unlink(path); unlink(info); return; }
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX }; strlcpy(a.sun_path, path, sizeof a.sun_path);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { if (fd >= 0) close(fd); return; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    pad_feed_fd = fd;
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s.%d", info, (int)getpid());
    FILE *f = fopen(tmp, "w"); if (f) { fprintf(f, "%s\n", path); fclose(f); rename(tmp, info); }
    static bool cleanup; if (!cleanup) { cleanup = true; atexit_b(^{ pad_feed_open(false); }); }
    fprintf(stderr, "nokcandu: controller fed by Nokcandu (%s)\n", path);
}
static bool pad_is_fed_device(int32_t which) {
    if (!pad_feed_on || !real_num_joysticks || !real_device_instance || !real_device_vendor) return false;
    int n = real_num_joysticks();
    for (int i = 0; i < n; i++) if (real_device_instance(i) == which) return real_device_vendor(i) == 0x28de;
    return false;
}
static void pad_feed_drain(void) {
    if (pad_feed_fd < 0) return;
    padfeed m;
    while (recv(pad_feed_fd, &m, sizeof m, 0) == (ssize_t)sizeof m) {
        if (pad_feed_which < 0 && real_num_joysticks && real_device_instance && real_device_vendor) {
            int n = real_num_joysticks();
            for (int i = 0; i < n; i++) if (real_device_vendor(i) == 0x28de) { pad_feed_which = real_device_instance(i); break; }
        }
        if (pad_feed_which < 0) continue;
        nok_sdl_event ev = {0};
        if (m.kind == 1) { ev.cbutton.type = m.value ? NOK_SDL_CBDOWN : NOK_SDL_CBUP; ev.cbutton.which = pad_feed_which; ev.cbutton.button = m.code; ev.cbutton.state = m.value != 0; }
        else if (m.kind == 2) { ev.caxis.type = NOK_SDL_CAXIS; ev.caxis.which = pad_feed_which; ev.caxis.axis = m.code; ev.caxis.value = m.value; }
        else continue;
        pad_push(ev);
    }
}

// Which profile applies now: the one the game in front asked for (re-read when it or the profile changes).
static void pad_check(void) {
    double now = pad_now();
    if (now - pad_last_check < 0.2) return;
    pad_last_check = now;
    pad_check_calibrate(now);
    {   // Players set in Nokcandu changed: controllers start again as their new players.
        int seats[PAD_IDS]; for (int i = 0; i < pad_ids_n; i++) seats[i] = pad_ids[i].seat;
        int n = pad_ids_n;
        pad_read_players(false);
        bool moved = n != pad_ids_n;
        for (int i = 0; i < pad_ids_n && i < n; i++) if (seats[i] != pad_ids[i].seat) moved = true;
        if (moved) { pad_drop_engines(); pad_report_players(); }
    }
    char active[PATH_MAX]; snprintf(active, sizeof active, "%s/pad-active", pad_state_dir);
    bool changed = pad_changed(active, &pad_active_mtime, &pad_active_ns);
    if (changed) {
        pid_t pid = 0; char path[PATH_MAX] = "";
        FILE *f = fopen(active, "r");
        if (f) { if (fscanf(f, "%d\n", &pid) != 1) pid = 0; if (!fgets(path, sizeof path, f)) path[0] = 0; fclose(f); }
        path[strcspn(path, "\r\n")] = 0;
        if (pid > 0 && kill(pid, 0) != 0) pid = 0;
        if (pid != pad_game_pid || strcmp(path, pad_profile_path)) {
            pad_drop_engines();
            pad_game_pid = pid; strlcpy(pad_profile_path, pid > 0 ? path : "", sizeof pad_profile_path);
            pad_profile_mtime = 0; pad_profile_ns = 0; pad_profile_text[0] = 0;
        }
    }
    if (pad_game_pid > 0 && kill(pad_game_pid, 0) != 0) { pad_drop_engines(); pad_game_pid = 0; pad_profile_path[0] = 0; pad_profile_text[0] = 0; }
    if (!pad_profile_text[0]) { pad_has_devices = false; if (pad_feed_fd >= 0) pad_feed_open(false); }
    if (pad_profile_path[0] && pad_changed(pad_profile_path, &pad_profile_mtime, &pad_profile_ns)) {
        pad_profile_text[0] = 0;
        FILE *f = fopen(pad_profile_path, "r");
        if (f) { size_t n = fread(pad_profile_text, 1, sizeof pad_profile_text - 1, f); pad_profile_text[n] = 0; fclose(f); }
        if (strncmp(pad_profile_text, "nokpad ", 7)) pad_profile_text[0] = 0;
        int kinds[9]; memcpy(kinds, pad_player_kind, sizeof kinds);
        pad_parse_players();
        pad_forget_own_texts();
        bool live = pad_profile_text[0] != 0 && !memcmp(kinds, pad_player_kind, sizeof kinds);
        for (int i = 0; i < PAD_MAX && live; i++) if (pads[i].used) {
            const char *text = pad_text_for(pads[i].which, pads[i].player);
            live = text && pe_update_profile(pads[i].e, text);
        }
        if (!live) pad_drop_engines();
        pad_has_devices = strstr(pad_profile_text, "\ndevice ") != NULL;
        pad_feed_open(strstr(pad_profile_text, "\nsource steam\n") != NULL);
        fprintf(stderr, "nokcandu: controller profile %s\n", pad_profile_text[0] ? pad_profile_path : "off");
    }
}
static void pad_tick_all(double now) {
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used) {
        double d = pe_next_deadline(pads[i].e);
        if (d && d <= now) pe_tick(pads[i].e, now);
    }
}
static int pad_next_wait_ms(double now, int timeout) {
    int ms = timeout;
    for (int i = 0; i < PAD_MAX; i++) if (pads[i].used) {
        double d = pe_next_deadline(pads[i].e);
        if (d) { int w = (int)ceil((d - now) * 1000); if (w < 1) w = 1; if (w < ms) ms = w; }
    }
    return ms;
}

static int nok_wait(nok_sdl_event *ev, int timeout) {
    pad_check();
    pad_feed_drain();
    { double t = pad_now(); if (st_last_wait > 0 && t - st_last_wait > st_max_gap) st_max_gap = t - st_last_wait; st_last_wait = t; st_ticks++; pad_status(t); }
    if (pad_pop(ev)) return 1;
    double now = pad_now();
    pad_tick_all(now);
    if (pad_pop(ev)) return 1;
    int wait_ms = pad_next_wait_ms(now, timeout);
    if (pad_feed_fd >= 0 && wait_ms > 4) wait_ms = 4;     // pick up Nokcandu's input promptly
    int r = real_wait(ev, wait_ms);
    now = pad_now();
    if (r && (ev->type == NOK_SDL_CADDED || ev->type == NOK_SDL_CREMOVED || ev->type == NOK_SDL_JADDED || ev->type == NOK_SDL_JREMOVED)) pad_feed_which = -1;
    if (r && pad_feed_on) {
        switch (ev->type) {
        case NOK_SDL_CAXIS: case NOK_SDL_CBDOWN: case NOK_SDL_CBUP: case NOK_SDL_CSENSOR:
        case NOK_SDL_CTOUCHDOWN: case NOK_SDL_CTOUCHMOTION: case NOK_SDL_CTOUCHUP:
        case NOK_SDL_JAXIS: case NOK_SDL_JHAT: case NOK_SDL_JBDOWN: case NOK_SDL_JBUP:
            if (pad_is_fed_device(ev->cbutton.which)) {   // raw input of the controller Nokcandu feeds: dropped
                pad_feed_drain();
                return pad_pop(ev) ? 1 : 0;
            }
        }
    }
    if (r) {
        if (ev->type == NOK_SDL_CREMOVED || ev->type == NOK_SDL_JREMOVED) {
            if (ev->type == NOK_SDL_JREMOVED) { pad_forget_player(ev->cbutton.which); pad_forget_identity(ev->cbutton.which); pad_report_players(); }
            for (int slot = 1; slot <= PE_MAX_DEVICES; slot++) if (slot_source_valid[slot] && slot_sources[slot] == ev->cbutton.which) {
                pe_engine *main = pad_main_engine();
                if (main) pe_release_device(main, slot, now);
                slot_source_valid[slot] = false;
            }
            slot_cached = 0;
        }
        int slot = 0;
        switch (ev->type) {
        case NOK_SDL_CAXIS: case NOK_SDL_CBDOWN: case NOK_SDL_CBUP: case NOK_SDL_CSENSOR:
        case NOK_SDL_JAXIS: case NOK_SDL_JHAT: case NOK_SDL_JBDOWN: case NOK_SDL_JBUP:
            slot = pad_slot_for(ev->cbutton.which); break;
        case NOK_SDL_JADDED: case NOK_SDL_JREMOVED: case NOK_SDL_CADDED:
            slot_cached = 0; break;
        }
        if (slot) {
            // One of the profile's devices: into the main controller's engine. What the profile uses doesn't also
            // reach the game from the device itself; the rest does.
            pe_engine *e = pad_main_engine();
            bool gp = pad_slot_gamepad(slot);
            switch (ev->type) {
            case NOK_SDL_CSENSOR: r = 0; break;
            case NOK_SDL_CBDOWN: case NOK_SDL_CBUP:
                if (gp && e) { pe_dev_button(e, slot, ev->cbutton.button, ev->type == NOK_SDL_CBDOWN, now); if (pe_dev_uses(e, slot, 0, ev->cbutton.button)) r = 0; }
                break;
            case NOK_SDL_CAXIS:
                if (gp && e) { pe_dev_axis(e, slot, ev->caxis.axis, ev->caxis.value, now); if (pe_dev_uses(e, slot, 2, ev->caxis.axis)) r = 0; }
                break;
            case NOK_SDL_JBDOWN: case NOK_SDL_JBUP:
                if (!gp && e) { pe_dev_button(e, slot, ev->cbutton.button, ev->type == NOK_SDL_JBDOWN, now); if (pe_dev_uses(e, slot, 0, ev->cbutton.button)) r = 0; }
                break;
            case NOK_SDL_JAXIS:
                if (!gp && e) { pe_dev_axis(e, slot, ev->caxis.axis, ev->caxis.value, now); if (pe_dev_uses(e, slot, 2, ev->caxis.axis)) r = 0; }
                break;
            case NOK_SDL_JHAT:
                if (!gp && e && ev->jhat.hat == 0) { pe_dev_hat(e, slot, ev->jhat.value, now); if (pe_dev_uses(e, slot, 1, 0)) r = 0; }
                break;
            }
            if (!r && pad_pop(ev)) return 1;
            if (!r) pad_tick_all(now);
            if (!r && pad_pop(ev)) return 1;
            return r;
        }
        switch (ev->type) {
        case NOK_SDL_CSENSOR: {             // gyro: Wine's driver has no use for it
            pe_engine *e = pad_engine_for(ev->csensor.which, true);
            if (ev->csensor.sensor == NOK_SDL_SENSOR_GYRO) { st_gyro++; st_gx = ev->csensor.data[0]; st_gy = ev->csensor.data[1]; st_gz = ev->csensor.data[2]; }
            if (e && ev->csensor.sensor == NOK_SDL_SENSOR_GYRO) pe_gyro(e, ev->csensor.data[0], ev->csensor.data[1], ev->csensor.data[2], now);
            if (e && ev->csensor.sensor == NOK_SDL_SENSOR_ACCEL) pe_accel(e, ev->csensor.data[0], ev->csensor.data[1], ev->csensor.data[2], now);
            r = 0; break; }
        case NOK_SDL_CBDOWN: case NOK_SDL_CBUP: {
            pe_engine *e = pad_engine_for(ev->cbutton.which, true);
            st_buttons++;
            if (e) { pe_button(e, ev->cbutton.button, ev->type == NOK_SDL_CBDOWN, now); r = 0; }
            break; }
        case NOK_SDL_CAXIS: {
            pe_engine *e = pad_engine_for(ev->caxis.which, true);
            st_axes++;
            if (e) { pe_axis(e, ev->caxis.axis, ev->caxis.value, now); r = 0; }
            break; }
        case NOK_SDL_CTOUCHDOWN: case NOK_SDL_CTOUCHMOTION: case NOK_SDL_CTOUCHUP: {
            pe_engine *e = pad_engine_for(ev->ctouch.which, true);
            if (e && pe_uses_touch(e) && ev->ctouch.touchpad == 0)
                pe_touch(e, ev->ctouch.finger, ev->type != NOK_SDL_CTOUCHUP, ev->ctouch.x, ev->ctouch.y, now);
            if (e && !pe_touch_passthrough(e)) r = 0;
            break; }
        case NOK_SDL_CREMOVED:
            slot_cached = 0;
            pad_forget_player(ev->cbutton.which);
            pad_forget_identity(ev->cbutton.which);
            pad_report_players();
            for (int i = 0; i < PAD_MAX; i++) if (pads[i].used && pads[i].which == ev->cbutton.which) {
                if (pads[i].main && pad_has_devices) { pe_release_main(pads[i].e, now); pads[i].which = -1; }
                else { pe_release_all(pads[i].e, now); pe_destroy(pads[i].e); pads[i].used = false; pads[i].main = false; }
            }
            break;
        }
    } else pad_tick_all(now);
    if (!r && pad_pop(ev)) return 1;
    return r;
}

static void *nok_open(int index) {
    void *c = real_open(index);
    pad_identify(c);
    if (c && real_device_instance) pad_player_of(real_device_instance(index));   // players in the order controllers open
    pad_report_players();
    if (c && real_sensor) { st_sensor_ok = real_sensor(c, NOK_SDL_SENSOR_GYRO, 1) == 0; real_sensor(c, NOK_SDL_SENSOR_ACCEL, 1); }   // gyro (and tilt) on, for profiles that use them
    fprintf(stderr, "nokcandu: controller %d opened; gyro %s\n", index, st_sensor_ok ? "on" : real_sensor ? "not available" : "unknown");
    return c;
}

// MARK: The controller games see (a profile's "present" line)

// The profile can ask for the controller to be presented as another one. Wine's SDL bus asks SDL for each
// controller's vendor, product, version and name when it creates the Windows device, so those answers decide what
// games see. Only Xbox is presented today: Wine's own gamepad reports already have the Xbox layout. Read once,
// when Wine first asks (the environment's pad-map is written before it starts); a change applies from the next start.
static struct { bool known, on; int kind; uint16_t vid, pid, version; const char *name; } pad_identity;
// Which later players take the identity too: those with a profile (same or their own); a player whose controller
// stays as it is keeps its own type. Maps from before co-op: everyone.
static bool pad_identity_player[9] = { true, true, true, true, true, true, true, true, true };
static uint16_t (*real_js_vendor)(void *), (*real_js_product)(void *), (*real_js_version)(void *);
static const char *(*real_gc_name)(void *), *(*real_js_name)(void *);
static int (*real_js_type)(void *);
static void pad_load_identity(void);
/// Only gamepads take the identity (SDL_JOYSTICK_TYPE_GAMECONTROLLER); wheels, sticks and others stay as they are.
static bool pad_presents(void *j) {
    pad_identify_joystick(j);
    pad_load_identity();
    if (!pad_identity.on || !j || (real_js_type && real_js_type(j) != 1)) return false;
    if (!real_instance) return true;
    int player = pad_player_of(real_instance(j));
    return pad_identity_player[player > 8 ? 8 : player];
}

static void pad_load_identity(void) {
    if (pad_identity.known) return;
    pad_identity.known = true;
    char path[PATH_MAX], line[256];
    struct stat st;
    snprintf(path, sizeof path, "%s/pad-driver-off", pad_state_dir);
    if (stat(path, &st) == 0) return;
    const char *home = getenv("HOME");
    if (home) {
        snprintf(path, sizeof path, "%s/Library/Application Support/Nokcandu/controller-profiles-off", home);
        if (stat(path, &st) == 0) return;
    }
    // The map that applies: a profile used everywhere (as the game half chooses, pad_activate), else this
    // environment's, else the game in front's (a shared launcher's games have maps of their own). Reading only the
    // environment's left a profile used everywhere unpresented.
    path[0] = 0;
    if (home) {
        char flag[PATH_MAX]; snprintf(flag, sizeof flag, "%s/Library/Application Support/Nokcandu/controller-profiles-everywhere", home);
        if (stat(flag, &st) == 0) snprintf(path, sizeof path, "%s.map", flag);
    }
    if (!path[0] || stat(path, &st) != 0) snprintf(path, sizeof path, "%s/pad-map", pad_state_dir);
    if (stat(path, &st) != 0 && pad_profile_path[0]) strlcpy(path, pad_profile_path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return;
    bool players = false, presented = false;
    while (fgets(line, sizeof line, f)) {
        // The presentation is player 1's (the first "present" line, before any player's or controller's block);
        // the player lines after it say which later players take it. Stopping at "present" (as before November 27,
        // 2026) never read them, so players left as they are were presented too.
        int n; char word[16];
        if (sscanf(line, "player %d %15s", &n, word) == 2) {
            if (!players) { players = true; for (int k = 2; k < 9; k++) pad_identity_player[k] = false; }
            if (n >= 2 && n <= 8) pad_identity_player[n] = strcmp(word, "asis") != 0 && strcmp(word, "end") != 0;
            if (!strcmp(word, "begin")) { while (fgets(line, sizeof line, f)) if (sscanf(line, "player %d %15s", &n, word) == 2 && !strcmp(word, "end")) break; }
            continue;
        }
        if (!strncmp(line, "controller ", 11) && strstr(line, " begin")) {
            while (fgets(line, sizeof line, f)) if (!strncmp(line, "controller ", 11) && strstr(line, " end")) break;
            continue;
        }
        if (presented || players || strncmp(line, "present ", 8)) continue;
        presented = true;
        if (!strncmp(line + 8, "xbox", 4)) {
            pad_identity.on = true; pad_identity.kind = 1; pad_identity.vid = 0x045E; pad_identity.pid = 0x02EA; pad_identity.version = 0x0408;
            pad_identity.name = "Xbox Wireless Controller";
        } else if (!strncmp(line + 8, "ds4", 3)) {
            // Imitated by Nokcandu's controller driver too (ds4-emulation.h).
            pad_identity.on = true; pad_identity.kind = 2; pad_identity.vid = 0x054C; pad_identity.pid = 0x05C4; pad_identity.version = 0x0100;
            pad_identity.name = "Wireless Controller";
        } else if (!strncmp(line + 8, "switchpro", 9)) {
            // Nokcandu's controller driver imitates the Pro's own reports and commands (switch-pro-emulation.h).
            pad_identity.on = true; pad_identity.kind = 3; pad_identity.vid = 0x057E; pad_identity.pid = 0x2009; pad_identity.version = 0x0200;
            pad_identity.name = "Pro Controller";
        }
    }
    fclose(f);
    if (pad_identity.on) fprintf(stderr, "nokcandu: controllers are presented as %s (%04x:%04x), from %s\n", pad_identity.name, pad_identity.vid, pad_identity.pid, path);
}
/// Asked by Nokcandu's controller driver (Engine/controller-hid) for each game controller it creates: 0 as it is,
/// 1 Xbox, 2 DualShock 4, 3 Switch Pro Controller.
__attribute__((visibility("default"))) int nokcandu_presented_controller(void *joystick) {
    return pad_bus && pad_presents(joystick) ? pad_identity.kind : 0;
}
// Only the Xbox identity is a rename (Wine's own reports already have its layout). A DualShock 4 or Switch Pro is
// presented by Nokcandu's controller driver, which imitates it and sets its IDs itself; with a driver that can't
// (Wine 10, or the stock module), those controllers stay as they are rather than get IDs their reports don't match.
static bool pad_renames(void *j) { return pad_presents(j) && pad_identity.kind == 1; }
static uint16_t nok_js_vendor(void *j) { return pad_renames(j) ? pad_identity.vid : real_js_vendor(j); }
static uint16_t nok_js_product(void *j) { return pad_renames(j) ? pad_identity.pid : real_js_product(j); }
static uint16_t nok_js_version(void *j) { return pad_renames(j) ? pad_identity.version : real_js_version(j); }
static const char *nok_gc_name(void *c) { pad_load_identity(); return pad_identity.on && pad_identity.kind == 1 && c ? pad_identity.name : real_gc_name(c); }
static const char *nok_js_name(void *j) { return pad_renames(j) ? pad_identity.name : real_js_name(j); }

// Rumble for controllers SDL can't rumble. Wine enables rumble for a controller only when a test
// SDL_JoystickRumble(0, 0, 0) succeeds as it opens it (dlls/winebus.sys/bus_sdl.c), and SDL has no rumble for
// some controllers (the original Steam Controller, whose haptics are its trackpads). Report rumble as supported and,
// when SDL can't play it, pass it to Nokcandu, which plays it with the controller's own haptics. The emulated
// DualShock 4 and Switch Pro send their rumble through the same call, so every route benefits.
static int (*real_js_rumble)(void *, uint16_t, uint16_t, uint32_t);
static uint16_t (*rumble_vendor)(void *), (*rumble_product)(void *);
static const char *(*rumble_name)(void *);
static int rumble_socket = -1;
static void rumble_forward(void *joystick, uint16_t low, uint16_t high, uint32_t ms) {
    const char *home = getenv("HOME");
    if (!home) return;
    if (rumble_socket < 0) {
        rumble_socket = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (rumble_socket < 0) return;
        fcntl(rumble_socket, F_SETFL, O_NONBLOCK);
    }
    struct sockaddr_un to = { .sun_family = AF_UNIX };
    snprintf(to.sun_path, sizeof to.sun_path, "%s/Library/Application Support/Nokcandu/controller-rumble.sock", home);
    char name[96] = "";
    const char *n = rumble_name && joystick ? rumble_name(joystick) : NULL;
    if (n) { strlcpy(name, n, sizeof name); for (char *c = name; *c; c++) if (*c == '\n' || *c == '\r') *c = ' '; }
    char msg[200];
    int len = snprintf(msg, sizeof msg, "nokcandu-rumble 1 %04x %04x %u %u %u %s",
                       rumble_vendor && joystick ? rumble_vendor(joystick) : 0, rumble_product && joystick ? rumble_product(joystick) : 0,
                       low, high, ms, name);
    if (len > 0) sendto(rumble_socket, msg, (size_t)(len < (int)sizeof msg ? len : (int)sizeof msg - 1), 0, (struct sockaddr *)&to, sizeof to);
}
static int nok_js_rumble(void *joystick, uint16_t low, uint16_t high, uint32_t ms) {
    if (real_js_rumble && real_js_rumble(joystick, low, high, ms) == 0) return 0;
    rumble_forward(joystick, low, high, ms);
    return 0;
}

// Only replace Wine's driver lookups. SDL also resolves its own public symbols
// internally; intercepting those puts our forwarding hook into SDL's dispatch
// table and recurses until the Wine driver hangs/crashes (including native HID).
static void *nok_dlsym(void *handle, const char *name) {
    void *real = dlsym(handle, name);
    if (!real || !name) return real;
    bool rumble = !strcmp(name, "SDL_JoystickRumble");
    if (!pad_bus && !rumble) return real;
    Dl_info caller;
    if (!dladdr(__builtin_return_address(0), &caller) || !caller.dli_fname) return real;
    const char *base = strrchr(caller.dli_fname, '/');
    base = base ? base + 1 : caller.dli_fname;
    if (strcmp(base, "winebus.so") && strcmp(base, "winebus.sys.so")) return real;
    if (rumble) {
        real_js_rumble = real;
        rumble_vendor = (uint16_t (*)(void *))dlsym(handle, "SDL_JoystickGetVendor");
        rumble_product = (uint16_t (*)(void *))dlsym(handle, "SDL_JoystickGetProduct");
        rumble_name = (const char *(*)(void *))dlsym(handle, "SDL_JoystickName");
        return (void *)nok_js_rumble;
    }
    if (!strcmp(name, "SDL_WaitEventTimeout")) {
        real_wait = real;
        if (!real_open) real_open = (void *(*)(int))dlsym(handle, "SDL_GameControllerOpen");
        if (!real_sensor) real_sensor = (int (*)(void *, int, int))dlsym(handle, "SDL_GameControllerSetSensorEnabled");
        real_num_joysticks = (int (*)(void))dlsym(handle, "SDL_NumJoysticks");
        real_device_instance = (int32_t (*)(int))dlsym(handle, "SDL_JoystickGetDeviceInstanceID");
        real_device_vendor = (uint16_t (*)(int))dlsym(handle, "SDL_JoystickGetDeviceVendor");
        real_device_product = (uint16_t (*)(int))dlsym(handle, "SDL_JoystickGetDeviceProduct");
        real_instance = (int32_t (*)(void *))dlsym(handle, "SDL_JoystickInstanceID");
        real_joystick = (void *(*)(void *))dlsym(handle, "SDL_GameControllerGetJoystick");
        id_path = (const char *(*)(void *))dlsym(handle, "SDL_JoystickPath");
        id_serial = (const char *(*)(void *))dlsym(handle, "SDL_JoystickGetSerial");
        id_vendor = (uint16_t (*)(void *))dlsym(handle, "SDL_JoystickGetVendor");
        id_product = (uint16_t (*)(void *))dlsym(handle, "SDL_JoystickGetProduct");
        real_is_gc = (int (*)(int))dlsym(handle, "SDL_IsGameController");
        fprintf(stderr, "nokcandu: controller remapping ready\n");
        return (void *)nok_wait;
    }
    if (!strcmp(name, "SDL_JoystickGetVendor")) {
        real_js_vendor = real;
        if (!real_js_type) real_js_type = (int (*)(void *))dlsym(handle, "SDL_JoystickGetType");
        return (void *)nok_js_vendor;
    }
    if (!strcmp(name, "SDL_JoystickGetProduct")) { real_js_product = real; return (void *)nok_js_product; }
    if (!strcmp(name, "SDL_JoystickGetProductVersion")) { real_js_version = real; return (void *)nok_js_version; }
    if (!strcmp(name, "SDL_GameControllerName")) { real_gc_name = real; return (void *)nok_gc_name; }
    if (!strcmp(name, "SDL_JoystickName")) { real_js_name = real; return (void *)nok_js_name; }
    if (!strcmp(name, "SDL_GameControllerOpen")) {
        real_open = real;
        if (!real_sensor) real_sensor = (int (*)(void *, int, int))dlsym(handle, "SDL_GameControllerSetSensorEnabled");
        return (void *)nok_open;
    }
    return real;
}
__attribute__((used)) static const struct { const void *replacement, *original; } nok_interpose_dlsym[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)nok_dlsym, (const void *)dlsym } };

static void install_pad_bus(const char *state_dir) {
    strlcpy(pad_state_dir, state_dir, sizeof pad_state_dir);
    pad_bus = true;
    (void)real_instance; (void)real_joystick;
}

// MARK: - Game half

static char pad_map_path[PATH_MAX];
static char pad_active_path[PATH_MAX];
static int pad_listen = -1;
static dispatch_source_t pad_src;
static CGEventFlags pad_flags;
static int pad_keys_down[128];
static atomic_int pad_buttons_down[PE_MOUSE_BUTTONS];

static CGEventFlags pad_flag_for(int k) {
    switch (k) {
    case 56: return kCGEventFlagMaskShift | 0x2;      case 60: return kCGEventFlagMaskShift | 0x4;
    case 59: return kCGEventFlagMaskControl | 0x1;    case 62: return kCGEventFlagMaskControl | 0x2000;
    case 58: return kCGEventFlagMaskAlternate | 0x20; case 61: return kCGEventFlagMaskAlternate | 0x40;
    case 55: return kCGEventFlagMaskCommand | 0x8;    case 54: return kCGEventFlagMaskCommand | 0x10;
    case 63: return kCGEventFlagMaskSecondaryFn;      case 57: return kCGEventFlagMaskAlphaShift;
    default: return 0;
    }
}
static void pad_post(CGEventRef cg) {
    if (!cg) return;
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    if (e) [NSApp postEvent:e atStart:NO];
}
static void pad_key(int k, bool down) {
    if (k < 0 || k >= 128) return;
    pad_keys_down[k] = down;
    CGEventFlags f = pad_flag_for(k);
    CGEventRef cg = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)k, down);
    if (!cg) return;
    if (f) {
        if (down) pad_flags |= f; else {
            pad_flags &= ~f;
            // keep the shared bit while the other side's key is still down
            for (int o = 54; o <= 63; o++) if (o != k && pad_keys_down[o] && (pad_flag_for(o) & ~(CGEventFlags)0xffff) == (f & ~(CGEventFlags)0xffff)) pad_flags |= pad_flag_for(o);
        }
        CGEventSetType(cg, kCGEventFlagsChanged);
    }
    CGEventSetFlags(cg, pad_flags);
    pad_post(cg);
}
static CGPoint pad_cursor(void) { CGEventRef e = CGEventCreate(NULL); CGPoint p = e ? CGEventGetLocation(e) : CGPointZero; if (e) CFRelease(e); return p; }
static void pad_mouse_button(int b, bool down) {
    if (b < 0 || b >= PE_MOUSE_BUTTONS) return;
    pad_buttons_down[b] = down;
    id ctl = controller();
    SEL buttonOnly = sel_registerName("nokcanduPostControllerButton:pressed:");
    if ([ctl respondsToSelector:buttonOnly]) {
        ((BOOL (*)(id, SEL, int, BOOL))objc_msgSend)(ctl, buttonOnly, b, down);
        return;
    }
    CGEventType t = b == 0 ? (down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp) : b == 1 ? (down ? kCGEventRightMouseDown : kCGEventRightMouseUp)
                                                                                           : (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp);
    CGMouseButton mb = b == 0 ? kCGMouseButtonLeft : b == 1 ? kCGMouseButtonRight : (CGMouseButton)(b == 2 ? 2 : b == 3 ? 3 : 4);
    CGEventRef cg = CGEventCreateMouseEvent(NULL, t, pad_cursor(), mb);
    if (cg) CGEventSetFlags(cg, pad_flags);
    pad_post(cg);
}
static unsigned long pad_moves_in, pad_moves_relative, pad_moves_warp;
// A relative move straight into Wine's event queue for the front game window (what a real mouse's movement
// becomes), whether or not the game is capturing the mouse. Main thread.
static bool pad_post_relative(int dx, int dy) {
    if (relative_type <= 0 || !orig_postEvent) return false;
    NSWindow *w = NSApp.keyWindow;
    id ctl = controller();
    if (![w isKindOfClass:objc_getClass("WineWindow")] || !ctl) return false;
    id q = ((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("queue"));
    if (!q) return false;
    char *ev = calloc(1, kEventAllocSize);
    if (!ev) return false;
    *(int *)(ev + kRefs) = 1;
    *(int *)(ev + kDeliver) = INT_MAX;
    *(int *)(ev + kType) = relative_type;
    *(void **)(ev + kWindow) = (void *)CFBridgingRetain(w);
    *(int *)(ev + kX) = dx;
    *(int *)(ev + kY) = dy;
    *(int *)(ev + kDrag) = NSEvent.pressedMouseButtons != 0 || pad_buttons_down[0] || pad_buttons_down[1];
    *(unsigned long *)(ev + kTime) = ((unsigned long (*)(id, SEL, NSTimeInterval))objc_msgSend)(ctl, sel_registerName("ticksForEventTime:"), NSProcessInfo.processInfo.systemUptime);
    cursor_left_pointer(ctl);
    ((void (*)(id, SEL, void *))orig_postEvent)(q, sel_registerName("postEvent:"), ev);
    release_ours(ev);
    return true;
}
static void pad_mouse_move(int dx, int dy, bool force_relative) {
    pad_moves_in++;
    if (atomic_load(&armed)) {                         // the game has the mouse captured: same path as raw mouse
        pad_moves_relative++;
        dispatch_async(raw_q, ^{ send_relative(dx, dy, NSEvent.pressedMouseButtons != 0 || pad_buttons_down[0] || pad_buttons_down[1]); });
        return;
    }
    // The game shows a cursor (menus): move the pointer you see, and Wine follows it. Hidden (mouse-look):
    // movement goes straight into the game.
    id ctl = controller();
    bool cursor_hidden = ctl && hidden_ivar >= 0 && *(BOOL *)((char *)(__bridge void *)ctl + hidden_ivar);
    if ((force_relative || cursor_hidden) && pad_post_relative(dx, dy)) { pad_moves_relative++; return; }
    pad_moves_warp++;
    CGPoint p = pad_cursor(); p.x += dx; p.y += dy;
    NSWindow *kw = NSApp.keyWindow;
    if (kw) {           // stay inside the game's window (Mac screen coordinates are y-down here)
        CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
        NSRect f = [kw contentRectForFrameRect:kw.frame];
        p.x = fmin(fmax(p.x, NSMinX(f) + 1), NSMaxX(f) - 2);
        p.y = fmin(fmax(p.y, top - NSMaxY(f) + 1), top - NSMinY(f) - 2);
    }
    bool drag = pad_buttons_down[0] || pad_buttons_down[1];
    CGEventRef cg = CGEventCreateMouseEvent(NULL, drag ? (pad_buttons_down[0] ? kCGEventLeftMouseDragged : kCGEventRightMouseDragged) : kCGEventMouseMoved,
                                            p, pad_buttons_down[1] && !pad_buttons_down[0] ? kCGMouseButtonRight : kCGMouseButtonLeft);
    if (!cg) return;
    CGEventSetIntegerValueField(cg, kCGMouseEventDeltaX, dx);
    CGEventSetIntegerValueField(cg, kCGMouseEventDeltaY, dy);
    CGWarpMouseCursorPosition(p);
    pad_post(cg);
}
static void pad_game_status(void) {
    static double last; double now = NSProcessInfo.processInfo.systemUptime;
    if (now - last < 2 || !pad_active_path[0]) return;
    last = now;
    char path[PATH_MAX]; snprintf(path, sizeof path, "%s-game", pad_active_path);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "game: %lu moves in (%lu relative, %lu by pointer), capturing %s, relative layout %d, raw mouse %s\n",
            pad_moves_in, pad_moves_relative, pad_moves_warp, atomic_load(&armed) ? "yes" : "no", relative_type, atomic_load(&raw_enabled) ? "on" : "off");
    fclose(f);
    pad_moves_in = pad_moves_relative = pad_moves_warp = 0;
}
static void pad_wheel(int n) { pad_post(CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, n)); }
static void pad_release_local(void) {
    for (int k = 0; k < 128; k++) if (pad_keys_down[k]) pad_key(k, false);
    for (int b = 0; b < PE_MOUSE_BUTTONS; b++) if (pad_buttons_down[b]) pad_mouse_button(b, false);
}

static const char *pad_active_map;   // the map named in pad-active: this game's, or the profile used everywhere
static void pad_write_active(bool active) {
    if (!pad_active_path[0]) return;
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s.%d", pad_active_path, getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    if (active) fprintf(f, "%d\n%s\n", getpid(), pad_active_map ? pad_active_map : pad_map_path); else fprintf(f, "0\n\n");
    fclose(f);
    rename(tmp, pad_active_path);
}
// Nokcandu sends a profile's mouse movement here while this game is in front. The profile also runs inside Wine's
// controller driver (pad-active) for what the game sees as the controller, unless "pad-driver-off" is present.
static char pad_driver_flag[PATH_MAX];
static char pad_off_flag[PATH_MAX];
static void pad_activate(void) {
    struct stat st;
    char everywhere[PATH_MAX]; snprintf(everywhere, sizeof everywhere, "%.*s-everywhere", (int)(strlen(pad_off_flag) - 4), pad_off_flag);
    // A profile used everywhere replaces the game's own here too (Nokcandu compiles it next to the flag), so what it
    // makes of the controller (remapped buttons, gyro as a stick, the emulated controller) reaches Windows games.
    // Before November 2026 the driver switched off instead, and only the profile's keys and mouse reached the game.
    static char everywhere_map[PATH_MAX];
    snprintf(everywhere_map, sizeof everywhere_map, "%s.map", everywhere);
    bool everywhere_on = stat(everywhere, &st) == 0;
    pad_active_map = everywhere_on ? everywhere_map : pad_map_path;
    bool driver = stat(pad_driver_flag, &st) != 0 && stat(pad_active_map, &st) == 0 && stat(pad_off_flag, &st) != 0;
    if (pad_listen < 0) {
        char path[104]; pad_socket_path(getpid(), path, sizeof path);
        if (path[0]) unlink(path);
        int s = path[0] ? socket(AF_UNIX, SOCK_DGRAM, 0) : -1;
        struct sockaddr_un a = { .sun_family = AF_UNIX }; strlcpy(a.sun_path, path, sizeof a.sun_path);
        if (s >= 0 && bind(s, (struct sockaddr *)&a, sizeof a) == 0) {
            fcntl(s, F_SETFL, O_NONBLOCK);
            pad_listen = s;
            pad_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)s, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(pad_src, ^{
                padmsg m;
                while (recv(pad_listen, &m, sizeof m, 0) == (ssize_t)sizeof m) {
                    if (!NSApp.isActive && m.kind != PADMSG_RELEASE && !(m.kind == PADMSG_KEY && !m.down) && !(m.kind == PADMSG_MOUSE_BUTTON && !m.down)) continue;
                    switch (m.kind) {
                    case PADMSG_KEY: pad_key(m.code, m.down); break;
                    case PADMSG_MOUSE_BUTTON: pad_mouse_button(m.code, m.down); break;
                    case PADMSG_MOUSE_MOVE: pad_mouse_move(m.dx, m.dy, m.code == 1); pad_game_status(); break;
                    case PADMSG_WHEEL: pad_wheel(m.code); break;
                    case PADMSG_RELEASE: pad_release_local(); break;
                    }
                }
            });
            dispatch_resume(pad_src);
            static char sockpath[104]; strlcpy(sockpath, path, sizeof sockpath);
            static char capability[120]; snprintf(capability, sizeof capability, "%s.buttons", path);
            if ([controller() respondsToSelector:sel_registerName("nokcanduPostControllerButton:pressed:")]) {
                FILE *f = fopen(capability, "w"); if (f) { fputs("1\n", f); fclose(f); }
            } else unlink(capability);
            atexit_b(^{ unlink(sockpath); unlink(capability); });
        } else if (s >= 0) close(s);
    }
    pad_write_active(driver);
}
static void pad_resign(void) {
    pad_release_local();
    // Only clear pad-active if it still names this process (another program of the game may be in front now).
    FILE *f = fopen(pad_active_path, "r"); int pid = 0;
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
    if (pid == getpid()) pad_write_active(false);
}

static void install_pad_game(const char *folder) {
    if (!folder) return;
    snprintf(pad_map_path, sizeof pad_map_path, "%s/pad-map", folder);
    snprintf(pad_active_path, sizeof pad_active_path, "%s/pad-active", folder);
    snprintf(pad_driver_flag, sizeof pad_driver_flag, "%s/pad-driver-off", folder);
    { const char *home = getenv("HOME"); if (home) snprintf(pad_off_flag, sizeof pad_off_flag, "%s/Library/Application Support/Nokcandu/controller-profiles-off", home); }
    // A game inside a shared launcher may have a profile of its own: pad-map.tsv routes its programs to it.
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    if (argc > 1) {
        char routes[PATH_MAX], own[PATH_MAX];
        snprintf(routes, sizeof routes, "%s/pad-map.tsv", folder);
        if (nokcandu_program_input(routes, argv[1], own, sizeof own)) strlcpy(pad_map_path, own, sizeof pad_map_path);
    }
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n) { pad_activate(); }];
    [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n) { pad_resign(); }];
    [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                usingBlock:^(__unused NSNotification *n) { pad_resign(); }];
    atexit_b(^{ pad_resign(); });
    if (NSApp.isActive) pad_activate();
}
