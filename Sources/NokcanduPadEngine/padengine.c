// Controller remapping engine. See padengine.h.
//
// Profile text: one setting per line, words separated by spaces, "key=value" options.
//   nokpad 1
//   gyro out=mouse|lstick|rstick|off on=1 min=6 max=14 lo=0 hi=75 smooth=4 tight=2 invx=0 invy=0 yaw=yaw|roll|both
//        stickfull=300 stickmin=0.1 cal=auto
//   stick 0|1 mode=pad|mouse|flick|keys|none to=0|1 dz=0.15 outer=0.95 sens=1500 power=1.5 flick360=4000
//        flicktime=0.1 keys=<up>,<down>,<left>,<right> (Mac key codes) invy=0
//   trigger 0|1 mode=pad|none soft=0.3 full=0.95
//   bind <layer> <input> press=<outs> tap=<outs> hold=<outs> double=<outs> turbo=<ms> sim=<input> simout=<outs>
//        holdtime=0.2 doubletime=0.22
// <outs>: comma-separated: pad:<button> trig:l|r key:<code> mouse:left|right|middle|back|forward wheel:up|down
//         gyro:on|off|toggle layer:hold:<n> layer:toggle:<n> none
//   device <slot 1…4> vendor=<n> product=<n> nth=<n> kind=joystick|gamepad join=0|1
//   axis <slot> <n> mode=off|pad|mouse to=lx|ly|rx|ry|lt|rt|x|y inv=0 half=0 dz=0.05 sens=1500 power=1.5 press=0.5
//        (half: rests at one end, like a pedal or throttle: 0…1)
//   stick/gyro lines with layer=<n>: that layer's own stick or gyro settings (while it's the top layer with them)
//   touch mode=off|mouse|scroll|zones sens=1500 scroll=12
//   tilt angle=30 invx=0 invy=0
//   macro <n> down:<out> up:<out> wait:<ms> text:<hex utf8> …      (outs: macro:<n>)
//   seq <n> in=<input>,<input>… step=0.4 out=<outs>
//   menu <n> stick=0|1 s0=<outs> … s7=<outs>                       (outs: menu:<n>; keyboard)
//   gyro … euro=1 mincut=5 beta=0.05 (a One Euro filter: steady when slow, quick when fast)
// Layer 0 is the base. A button with no binding in any active layer stays itself (a controller button).
#include "padengine.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define MAX_LAYERS 8
#define MAX_OUTS 6
#define MAX_TIMERS 64
#define KEYS 128
#define PULSE 0.03          // a tap's outputs stay down this long
#define SIM_WINDOW 0.05
#define MAX_MACROS 16
#define MAX_STEPS 48
#define MAX_SEQS 16
#define MAX_MENUS 8

enum { O_NONE, O_PAD, O_TRIG, O_KEY, O_MOUSE, O_WHEEL, O_GYRO_ON, O_GYRO_OFF, O_GYRO_TOGGLE, O_LAYER_HOLD, O_LAYER_TOGGLE,
       O_MACRO, O_MENU, O_KEYBOARD, O_CALIBRATE, O_RUMBLE };
typedef struct { unsigned char kind; short code; } out_t;
typedef struct { out_t o[MAX_OUTS]; int n; } outs_t;
typedef struct {
    bool set;
    outs_t press, tap, hold, dbl, sim;
    int sim_with;          // -1 none
    double turbo;          // seconds; 0 off
    double hold_time, double_time;
} binding_t;

enum { S_PAD, S_MOUSE, S_FLICK, S_KEYS, S_NONE, S_DIRS, S_SCROLL };
typedef struct {
    int mode, to;
    double dz, outer, sens, power, flick360, flicktime;
    int keys[4];
    bool invy;
    double xs, ys;               // left/right and up/down speed (1 = as set)
    double ramp, ramptime, edge, ramp_t;   // mouse: speed up the longer it's held at the edge
    // state
    double x, y;                 // −1…1, y up
    bool flicking; double flick_left, flick_rate, last_angle; bool in_flick;
    int keys_down[4];
    double rest_x, rest_y;
} stick_t;

enum { G_OFF, G_MOUSE, G_LSTICK, G_RSTICK };
enum { Y_YAW, Y_ROLL, Y_BOTH };

enum { A_OFF, A_PAD, A_MOUSE };
typedef struct {
    int mode, to; bool inv, half, set; double dz, sens, power, press;
    double v;                    // now, shaped (−1…1, or 0…1 for half)
    bool pos, neg;               // past the press point
} dev_axis_t;
typedef struct {
    bool set, gamepad, join; int vendor, product, nth;
    dev_axis_t ax[PE_DEV_AXES];
    int hat;
} device_t;

typedef struct { double at; int kind; int a, b; } timer_t_;
enum { T_RELEASE_OUTS, T_HOLD, T_DOUBLE_WAIT, T_TURBO, T_SIM_WAIT, T_MACRO };

typedef struct {
    int out, yaw; bool def, invx, invy, autocal, euro;
    double min, max, lo, hi, smooth, tight, stickfull, stickmin, xs, ys, yw, rw, mincut, beta;
} gyro_cfg_t;
enum { MS_DOWN, MS_UP, MS_WAIT, MS_TEXT };
typedef struct { unsigned char kind; out_t o; int ms; char *text; } mstep_t;
typedef struct { mstep_t step[MAX_STEPS]; int n; } macro_t;
typedef struct { int in[8]; int n; double step; outs_t out; } seq_t;
typedef struct { bool set; int stick; int n; outs_t slice[8]; } menu_t;
enum { TM_OFF, TM_MOUSE, TM_SCROLL, TM_ZONES };

// What a held input is doing (captured at press, so a layer change can't strand a key).
enum { P_IDLE, P_PRESS, P_WAIT_HOLD, P_HOLDING, P_WAIT_DOUBLE, P_DOUBLE, P_SIM_PENDING, P_SIM, P_LATE };
typedef struct {
    int phase;
    const binding_t *b;
    double since;
    outs_t active;              // outputs held down for this input
    bool passthrough;
} press_t;

struct pe_engine {
    pe_sink sink;
    binding_t bind[MAX_LAYERS][PE_ALL_INPUTS];
    bool layer_toggled[MAX_LAYERS];
    int layer_holds[MAX_LAYERS];
    press_t press[PE_ALL_INPUTS];
    bool physical[PE_ALL_INPUTS];
    device_t dev[PE_MAX_DEVICES + 1];    // 1…4
    int ndev;
    // outputs (reference counts)
    int pad_ref[PE_PAD_BUTTONS], trig_ref[2], key_ref[KEYS], mouse_ref[PE_MOUSE_BUTTONS];
    int axis_out[PE_AXES];
    int raw_axis[PE_AXES];
    stick_t stick[2];
    int trig_mode[2]; double trig_soft[2], trig_full[2];
    // gyro
    int gyro_out, gyro_yaw; bool gyro_default, gyro_toggled; int gyro_on_holds, gyro_off_holds;
    double g_min, g_max, g_lo, g_hi, g_smooth, g_tight, g_stickfull, g_stickmin;
    bool g_invx, g_invy, g_autocal, uses_gyro;
    double g_xs, g_ys, g_yw, g_rw;     // how much turning (yaw) and tilting (roll) move left and right
    double cal_x, cal_y, cal_z, still_since, last_gyro;
    double smooth_buf[16][2]; int smooth_i;
    double g_rest_x, g_rest_y, gyro_stick_x, gyro_stick_y;
    double last_tick;
    timer_t_ timers[MAX_TIMERS]; int ntimers;
    double m_rest_x, m_rest_y;
    outs_t pulse_store[MAX_TIMERS];      // outputs of taps waiting to be released
    int shown_layer, shown_gyro;          // last state reported to sink.state
    // Layers with their own stick or gyro settings, and which layer's apply now.
    stick_t stick_cfg[MAX_LAYERS][2]; bool stick_has[MAX_LAYERS][2]; int stick_layer[2];
    gyro_cfg_t gyro_cfg[MAX_LAYERS]; bool gyro_has[MAX_LAYERS]; int gyro_layer;
    bool g_euro; double g_mincut, g_beta, eu_x[2], eu_dx[2], eu_prev[2]; bool eu_init;
    double scroll_rest;
    // touchpad
    int touch_mode; double touch_sens, touch_scroll; bool f_down[2]; double f_x[2], f_y[2]; int touch_zone, touch_click_in;
    // tilt
    bool tilt_on; double tilt_angle, pitch_neutral; bool tilt_invx, tilt_invy, pitch_init;
    // macros, sequences, radial menus
    macro_t macros[MAX_MACROS]; int macro_pos[MAX_MACROS]; bool macro_run[MAX_MACROS]; outs_t macro_held[MAX_MACROS];
    seq_t seqs[MAX_SEQS]; int hist_in[8]; double hist_t[8]; int nhist;
    menu_t menus[MAX_MENUS]; int menu_open, menu_sel;
    // calibration: 1 automatic (set down), 2 asked for
    int cal_mode; double cal_start, cal_sum[3], cal_prev[3]; int cal_n; bool cal_done; float cal_shown;
};
static void apply_layers(pe_engine *e);
static void run_macro(pe_engine *e, int n, double now);
static void menu_begin(pe_engine *e, int n);
static void menu_end(pe_engine *e);
static void pulse(pe_engine *e, const outs_t *o, double now);

static const char *input_names[PE_INPUTS] = {
    "a", "b", "x", "y", "back", "guide", "start", "ls", "rs", "lb", "rb", "up", "down", "left", "right", "misc",
    "paddle1", "paddle2", "paddle3", "paddle4", "touchpad", "lt", "rt", "ltfull", "rtfull",
    "lsup", "lsdown", "lsleft", "lsright", "rsup", "rsdown", "rsleft", "rsright",
    "tz1", "tz2", "tz3", "tz4", "tc1", "tc2", "tc3", "tc4", "tiltleft", "tiltright", "tiltfwd", "tiltback"
};
static int dev_in(int slot, int k) { return PE_INPUTS + (slot - 1) * PE_DEV_INPUTS + k; }
enum { K_HAT = PE_DEV_BUTTONS, K_AXIS = PE_DEV_BUTTONS + 4 };
static const char hat_names[4] = { 'u', 'r', 'd', 'l' };
int pe_input_named(const char *n) {
    for (int i = 0; i < PE_INPUTS; i++) if (!strcmp(n, input_names[i])) return i;
    // d<slot>b<n>, d<slot>h<u|r|d|l>, d<slot>a<n><p|n>
    if (n[0] == 'd' && n[1] >= '1' && n[1] <= '0' + PE_MAX_DEVICES && n[2]) {
        int slot = n[1] - '0';
        const char *r = n + 3;
        if (n[2] == 'b') { char *end; long b = strtol(r, &end, 10); if (end != r && !*end && b >= 0 && b < PE_DEV_BUTTONS) return dev_in(slot, (int)b); }
        if (n[2] == 'h' && r[0] && !r[1]) for (int h = 0; h < 4; h++) if (r[0] == hat_names[h]) return dev_in(slot, K_HAT + h);
        if (n[2] == 'a') {
            char *end; long a = strtol(r, &end, 10);
            if (end != r && a >= 0 && a < PE_DEV_AXES && (end[0] == 'p' || end[0] == 'n') && !end[1]) return dev_in(slot, K_AXIS + 2 * (int)a + (end[0] == 'n'));
        }
    }
    return -1;
}
const char *pe_input_name(int i) {
    if (i >= 0 && i < PE_INPUTS) return input_names[i];
    if (i < PE_INPUTS || i >= PE_ALL_INPUTS) return "?";
    static char buf[4][12]; static int turn; char *b = buf[turn++ & 3];
    int slot = (i - PE_INPUTS) / PE_DEV_INPUTS + 1, k = (i - PE_INPUTS) % PE_DEV_INPUTS;
    if (k < K_HAT) snprintf(b, 12, "d%db%d", slot, k);
    else if (k < K_AXIS) snprintf(b, 12, "d%dh%c", slot, hat_names[k - K_HAT]);
    else snprintf(b, 12, "d%da%d%c", slot, (k - K_AXIS) / 2, (k - K_AXIS) % 2 ? 'n' : 'p');
    return b;
}
// Which input of a device an engine input is (slot 0 when it's the controller's own).
static int dev_slot(int in) { return in < PE_INPUTS || in >= PE_ALL_INPUTS ? 0 : (in - PE_INPUTS) / PE_DEV_INPUTS + 1; }
static int dev_key(int in) { return (in - PE_INPUTS) % PE_DEV_INPUTS; }

// MARK: Parsing

static bool parse_out(const char *s, out_t *o) {
    char buf[48]; strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    char *c = strchr(buf, ':');
    char *v = c ? c + 1 : NULL;
    if (c) *c = 0;
    o->code = 0;
    if (!strcmp(buf, "none")) { o->kind = O_NONE; return true; }
    if (!strcmp(buf, "keyboard")) { o->kind = O_KEYBOARD; return true; }
    if (!strcmp(buf, "calibrate")) { o->kind = O_CALIBRATE; return true; }
    if (!strcmp(buf, "rumble")) { o->kind = O_RUMBLE; return true; }
    if (!v) return false;
    if (!strcmp(buf, "macro")) { int n = atoi(v); if (n < 0 || n >= MAX_MACROS) return false; o->kind = O_MACRO; o->code = n; return true; }
    if (!strcmp(buf, "menu")) { int n = atoi(v); if (n < 0 || n >= MAX_MENUS) return false; o->kind = O_MENU; o->code = n; return true; }
    if (!strcmp(buf, "pad")) { int i = pe_input_named(v); if (i < 0 || i >= PE_PAD_BUTTONS) return false; o->kind = O_PAD; o->code = i; return true; }
    if (!strcmp(buf, "trig")) { o->kind = O_TRIG; o->code = v[0] == 'r'; return true; }
    if (!strcmp(buf, "key")) { int k = atoi(v); if (k < 0 || k >= KEYS) return false; o->kind = O_KEY; o->code = k; return true; }
    if (!strcmp(buf, "mouse")) {
        static const char *m[] = {"left", "right", "middle", "back", "forward"};
        for (int i = 0; i < PE_MOUSE_BUTTONS; i++) if (!strcmp(v, m[i])) { o->kind = O_MOUSE; o->code = i; return true; }
        return false;
    }
    if (!strcmp(buf, "wheel")) { o->kind = O_WHEEL; o->code = strcmp(v, "down") ? 1 : -1; return true; }
    if (!strcmp(buf, "gyro")) { o->kind = !strcmp(v, "on") ? O_GYRO_ON : !strcmp(v, "off") ? O_GYRO_OFF : O_GYRO_TOGGLE; return true; }
    if (!strcmp(buf, "layer")) {
        char *c2 = strchr(v, ':'); if (!c2) return false; *c2 = 0;
        int n = atoi(c2 + 1); if (n < 1 || n >= MAX_LAYERS) return false;
        o->kind = !strcmp(v, "toggle") ? O_LAYER_TOGGLE : O_LAYER_HOLD; o->code = n; return true;
    }
    return false;
}
static void parse_outs(const char *s, outs_t *outs) {
    outs->n = 0;
    char buf[256]; strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    char *save, *t = strtok_r(buf, ",", &save);
    while (t && outs->n < MAX_OUTS) { out_t o; if (parse_out(t, &o)) outs->o[outs->n++] = o; t = strtok_r(NULL, ",", &save); }
}
static double opt_d(const char *v, double d) { return v ? atof(v) : d; }
static void save_gyro(const pe_engine *e, gyro_cfg_t *c) {
    *c = (gyro_cfg_t){ e->gyro_out, e->gyro_yaw, e->gyro_default, e->g_invx, e->g_invy, e->g_autocal, e->g_euro,
                       e->g_min, e->g_max, e->g_lo, e->g_hi, e->g_smooth, e->g_tight, e->g_stickfull, e->g_stickmin,
                       e->g_xs, e->g_ys, e->g_yw, e->g_rw, e->g_mincut, e->g_beta };
}
static void load_gyro(pe_engine *e, const gyro_cfg_t *c) {
    e->gyro_out = c->out; e->gyro_yaw = c->yaw; e->gyro_default = c->def; e->g_invx = c->invx; e->g_invy = c->invy;
    e->g_autocal = c->autocal; e->g_euro = c->euro; e->g_min = c->min; e->g_max = c->max; e->g_lo = c->lo; e->g_hi = c->hi;
    e->g_smooth = c->smooth; e->g_tight = c->tight; e->g_stickfull = c->stickfull; e->g_stickmin = c->stickmin;
    e->g_xs = c->xs; e->g_ys = c->ys; e->g_yw = c->yw; e->g_rw = c->rw; e->g_mincut = c->mincut; e->g_beta = c->beta;
}
static int hexval(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }

pe_engine *pe_create(const char *text, pe_sink sink) {
    if (!text || strncmp(text, "nokpad ", 7)) return NULL;
    pe_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->sink = sink;
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        k->mode = S_PAD; k->to = s; k->dz = 0.12; k->outer = 0.95; k->sens = 1500; k->power = 1.5;
        k->flick360 = 4000; k->flicktime = 0.1; k->xs = 1; k->ys = 1; k->keys[0] = 13; k->keys[1] = 1; k->keys[2] = 0; k->keys[3] = 2;  // W S A D
        e->trig_soft[s] = 0.3; e->trig_full[s] = 0.95;
    }
    e->gyro_out = G_OFF; e->gyro_default = true; e->g_min = 8; e->g_max = 8; e->g_lo = 0; e->g_hi = 75;
    e->g_smooth = 0; e->g_tight = 0; e->g_xs = 1; e->g_ys = 1; e->g_yw = 1; e->g_rw = 0; e->g_stickfull = 300; e->g_stickmin = 0.1; e->g_autocal = true;
    e->g_mincut = 5; e->g_beta = 0.05;
    for (int l = 0; l < MAX_LAYERS; l++) for (int s2 = 0; s2 < 2; s2++) e->stick_cfg[l][s2] = e->stick[s2];
    e->touch_sens = 1500; e->touch_scroll = 12; e->touch_zone = -1; e->touch_click_in = -1;
    e->tilt_angle = 30; e->menu_open = -1; e->menu_sel = -1;
    char *copy = strdup(text), *lsave;
    for (char *line = strtok_r(copy, "\n", &lsave); line; line = strtok_r(NULL, "\n", &lsave)) {
        char *words[64]; int nw = 0; char *wsave;
        for (char *w = strtok_r(line, " \t\r", &wsave); w && nw < 64; w = strtok_r(NULL, " \t\r", &wsave)) words[nw++] = w;
        if (!nw) continue;
        // A macro's steps are words of their own ("down:key:13"), not options.
        if (!strcmp(words[0], "macro") && nw > 1) {
            int n = atoi(words[1]); if (n < 0 || n >= MAX_MACROS) continue;
            macro_t *m = &e->macros[n];
            for (int i = 2; i < nw && m->n < MAX_STEPS; i++) {
                char *c = strchr(words[i], ':'); if (!c) continue;
                *c = 0; const char *k = words[i], *v = c + 1;
                mstep_t st = { 0 };
                if (!strcmp(k, "down") || !strcmp(k, "up")) { if (!parse_out(v, &st.o)) continue; st.kind = !strcmp(k, "down") ? MS_DOWN : MS_UP; }
                else if (!strcmp(k, "wait")) { st.kind = MS_WAIT; st.ms = atoi(v); if (st.ms < 0) st.ms = 0; if (st.ms > 60000) st.ms = 60000; }
                else if (!strcmp(k, "text")) {
                    size_t len = strlen(v) / 2; char *t = malloc(len + 1); if (!t) continue;
                    size_t j = 0; for (; j < len; j++) { int h = hexval(v[2 * j]), l2 = hexval(v[2 * j + 1]); if (h < 0 || l2 < 0) break; t[j] = (char)(h * 16 + l2); }
                    t[j] = 0; st.kind = MS_TEXT; st.text = t;
                } else continue;
                m->step[m->n++] = st;
            }
            continue;
        }
        // options
        const char *opt_k[64], *opt_v[64]; int no = 0;
        for (int i = 1; i < nw; i++) { char *eq = strchr(words[i], '='); if (eq) { *eq = 0; opt_k[no] = words[i]; opt_v[no] = eq + 1; no++; } }
        #define OPT(name) ({ const char *_r = NULL; for (int _i = 0; _i < no; _i++) if (!strcmp(opt_k[_i], name)) _r = opt_v[_i]; _r; })
        if (!strcmp(words[0], "gyro")) {
            int L = (int)opt_d(OPT("layer"), 0); if (L < 0 || L >= MAX_LAYERS) continue;
            gyro_cfg_t base; save_gyro(e, &base);
            const char *o = OPT("out");
            if (o) e->gyro_out = !strcmp(o, "mouse") ? G_MOUSE : !strcmp(o, "lstick") ? G_LSTICK : !strcmp(o, "rstick") ? G_RSTICK : G_OFF;
            const char *y = OPT("yaw");
            if (y) e->gyro_yaw = !strcmp(y, "roll") ? Y_ROLL : !strcmp(y, "both") ? Y_BOTH : Y_YAW;
            e->gyro_default = opt_d(OPT("on"), 1) != 0;
            e->g_min = opt_d(OPT("min"), e->g_min); e->g_max = opt_d(OPT("max"), e->g_min);
            e->g_lo = opt_d(OPT("lo"), e->g_lo); e->g_hi = opt_d(OPT("hi"), e->g_hi);
            e->g_smooth = opt_d(OPT("smooth"), 0); e->g_tight = opt_d(OPT("tight"), 0);
            e->g_invx = opt_d(OPT("invx"), 0) != 0; e->g_invy = opt_d(OPT("invy"), 0) != 0;
            e->g_stickfull = opt_d(OPT("stickfull"), 300); e->g_stickmin = opt_d(OPT("stickmin"), 0.1);
            const char *c = OPT("cal"); e->g_autocal = !c || strcmp(c, "off");
            e->g_xs = opt_d(OPT("xs"), 1); e->g_ys = opt_d(OPT("ys"), 1);
            double yw = e->gyro_yaw == Y_ROLL ? 0 : 1, rw = e->gyro_yaw == Y_YAW ? 0 : 1;
            e->g_yw = opt_d(OPT("yw"), yw); e->g_rw = opt_d(OPT("rw"), rw);
            e->g_euro = opt_d(OPT("euro"), 0) != 0; e->g_mincut = opt_d(OPT("mincut"), 5); e->g_beta = opt_d(OPT("beta"), 0.05);
            save_gyro(e, &e->gyro_cfg[L]); e->gyro_has[L] = true;
            if (L > 0) load_gyro(e, &base);
        } else if (!strcmp(words[0], "stick") && nw > 1) {
            int s = atoi(words[1]); if (s < 0 || s > 1) continue;
            int L = (int)opt_d(OPT("layer"), 0); if (L < 0 || L >= MAX_LAYERS) continue;
            stick_t *k = &e->stick_cfg[L][s];
            e->stick_has[L][s] = true;
            const char *m = OPT("mode");
            if (m) k->mode = !strcmp(m, "mouse") ? S_MOUSE : !strcmp(m, "flick") ? S_FLICK : !strcmp(m, "keys") ? S_KEYS : !strcmp(m, "none") ? S_NONE : !strcmp(m, "dirs") ? S_DIRS : !strcmp(m, "scroll") ? S_SCROLL : S_PAD;
            k->to = (int)opt_d(OPT("to"), s) ? 1 : 0;
            k->dz = opt_d(OPT("dz"), k->dz); k->outer = opt_d(OPT("outer"), k->outer);
            k->sens = opt_d(OPT("sens"), k->sens); k->power = opt_d(OPT("power"), k->power);
            k->flick360 = opt_d(OPT("flick360"), k->flick360); k->flicktime = opt_d(OPT("flicktime"), k->flicktime);
            k->invy = opt_d(OPT("invy"), 0) != 0;
            k->xs = opt_d(OPT("xs"), 1); k->ys = opt_d(OPT("ys"), 1);
            k->ramp = opt_d(OPT("ramp"), 0); k->ramptime = opt_d(OPT("ramptime"), 0.4); k->edge = opt_d(OPT("edge"), 0.9);
            const char *ks = OPT("keys");
            if (ks) sscanf(ks, "%d,%d,%d,%d", &k->keys[0], &k->keys[1], &k->keys[2], &k->keys[3]);
        } else if (!strcmp(words[0], "trigger") && nw > 1) {
            int t = atoi(words[1]); if (t < 0 || t > 1) continue;
            const char *m = OPT("mode"); if (m) e->trig_mode[t] = !strcmp(m, "none") ? 1 : 0;
            e->trig_soft[t] = opt_d(OPT("soft"), e->trig_soft[t]); e->trig_full[t] = opt_d(OPT("full"), e->trig_full[t]);
        } else if (!strcmp(words[0], "touch")) {
            const char *m = OPT("mode");
            e->touch_mode = !m ? TM_OFF : !strcmp(m, "mouse") ? TM_MOUSE : !strcmp(m, "scroll") ? TM_SCROLL : !strcmp(m, "zones") ? TM_ZONES : TM_OFF;
            e->touch_sens = opt_d(OPT("sens"), 1500); e->touch_scroll = opt_d(OPT("scroll"), 12);
        } else if (!strcmp(words[0], "tilt")) {
            e->tilt_angle = opt_d(OPT("angle"), 30); e->tilt_invx = opt_d(OPT("invx"), 0) != 0; e->tilt_invy = opt_d(OPT("invy"), 0) != 0;
        } else if (!strcmp(words[0], "seq") && nw > 1) {
            int n = atoi(words[1]); if (n < 0 || n >= MAX_SEQS) continue;
            seq_t *q = &e->seqs[n]; q->n = 0;
            const char *in = OPT("in");
            if (in) {
                char buf[256]; strncpy(buf, in, sizeof buf - 1); buf[sizeof buf - 1] = 0;
                char *sv, *t = strtok_r(buf, ",", &sv);
                while (t && q->n < 8) { int i = pe_input_named(t); if (i >= 0) q->in[q->n++] = i; t = strtok_r(NULL, ",", &sv); }
            }
            q->step = opt_d(OPT("step"), 0.4);
            const char *o = OPT("out"); if (o) parse_outs(o, &q->out);
            if (q->n < 2) q->n = 0;
        } else if (!strcmp(words[0], "menu") && nw > 1) {
            int n = atoi(words[1]); if (n < 0 || n >= MAX_MENUS) continue;
            menu_t *mn = &e->menus[n]; mn->set = true; mn->stick = (int)opt_d(OPT("stick"), 1) ? 1 : 0; mn->n = 0;
            for (int i = 0; i < 8; i++) {
                char key[4]; snprintf(key, sizeof key, "s%d", i);
                const char *o = OPT(key); if (!o) break;
                parse_outs(o, &mn->slice[i]); mn->n = i + 1;
            }
        } else if (!strcmp(words[0], "device") && nw > 1) {
            int d = atoi(words[1]); if (d < 1 || d > PE_MAX_DEVICES) continue;
            device_t *v = &e->dev[d];
            v->set = true;
            v->vendor = (int)opt_d(OPT("vendor"), 0); v->product = (int)opt_d(OPT("product"), 0); v->nth = (int)opt_d(OPT("nth"), 0);
            const char *k = OPT("kind"); v->gamepad = k && !strcmp(k, "gamepad");
            v->join = v->gamepad && opt_d(OPT("join"), 0) != 0;
            if (d > e->ndev) e->ndev = d;
        } else if (!strcmp(words[0], "axis") && nw > 2) {
            int d = atoi(words[1]), n = atoi(words[2]);
            if (d < 1 || d > PE_MAX_DEVICES || n < 0 || n >= PE_DEV_AXES) continue;
            dev_axis_t *a = &e->dev[d].ax[n];
            a->set = true;
            const char *m = OPT("mode"); a->mode = m && !strcmp(m, "pad") ? A_PAD : m && !strcmp(m, "mouse") ? A_MOUSE : A_OFF;
            const char *t = OPT("to");
            static const char *tos[] = { "lx", "ly", "rx", "ry", "lt", "rt" };
            a->to = 0;
            if (t) { for (int i = 0; i < 6; i++) if (!strcmp(t, tos[i])) a->to = i; if (!strcmp(t, "x")) a->to = 0; if (!strcmp(t, "y")) a->to = 1; }
            a->inv = opt_d(OPT("inv"), 0) != 0; a->half = opt_d(OPT("half"), 0) != 0;
            a->dz = opt_d(OPT("dz"), 0.05); a->sens = opt_d(OPT("sens"), 1500); a->power = opt_d(OPT("power"), 1.5); a->press = opt_d(OPT("press"), 0.5);
        } else if (!strcmp(words[0], "bind") && nw > 2) {
            int l = atoi(words[1]), in = pe_input_named(words[2]);
            if (l < 0 || l >= MAX_LAYERS || in < 0) continue;
            binding_t *b = &e->bind[l][in];
            memset(b, 0, sizeof *b);
            b->set = true; b->sim_with = -1; b->hold_time = 0.2; b->double_time = 0.22;
            const char *v;
            if ((v = OPT("press"))) parse_outs(v, &b->press);
            if ((v = OPT("tap"))) parse_outs(v, &b->tap);
            if ((v = OPT("hold"))) parse_outs(v, &b->hold);
            if ((v = OPT("double"))) parse_outs(v, &b->dbl);
            if ((v = OPT("simout"))) parse_outs(v, &b->sim);
            if ((v = OPT("sim"))) b->sim_with = pe_input_named(v);
            b->turbo = opt_d(OPT("turbo"), 0) / 1000.0;
            b->hold_time = opt_d(OPT("holdtime"), b->hold_time); b->double_time = opt_d(OPT("doubletime"), b->double_time);
            // tap with nothing else behaves as press
            if (b->tap.n && !b->hold.n && !b->dbl.n && !b->press.n) { b->press = b->tap; b->tap.n = 0; }
        }
        #undef OPT
    }
    free(copy);
    for (int s2 = 0; s2 < 2; s2++) { e->stick[s2] = e->stick_cfg[0][s2]; e->stick_has[0][s2] = true; }
    if (!e->gyro_has[0]) { save_gyro(e, &e->gyro_cfg[0]); e->gyro_has[0] = true; }
    load_gyro(e, &e->gyro_cfg[0]);
    // A device that joins the controller: its sticks and triggers are the controller's unless set otherwise.
    for (int d = 1; d <= PE_MAX_DEVICES; d++) {
        device_t *v = &e->dev[d];
        for (int n = 0; n < PE_DEV_AXES; n++) {
            dev_axis_t *a = &v->ax[n];
            if (!a->set) { a->dz = 0.05; a->sens = 1500; a->power = 1.5; a->press = 0.5; if (v->join && n < 6) { a->mode = A_PAD; a->to = n; a->dz = 0; } }
        }
    }
    e->uses_gyro = false;
    for (int l = 0; l < MAX_LAYERS; l++) if (e->gyro_has[l] && e->gyro_cfg[l].out != G_OFF) e->uses_gyro = true;
    for (int i = PE_TILT_LEFT; i <= PE_TILT_BACK; i++) for (int l = 0; l < MAX_LAYERS; l++) if (e->bind[l][i].set) e->tilt_on = true;
    e->shown_layer = 0; e->shown_gyro = e->gyro_out == G_OFF ? -1 : e->gyro_default ? 1 : 0;
    for (int i = 0; i < 2; i++) e->stick[i].last_angle = NAN;
    return e;
}

void pe_destroy(pe_engine *e) {
    if (!e) return;
    for (int m = 0; m < MAX_MACROS; m++) for (int i = 0; i < e->macros[m].n; i++) free(e->macros[m].step[i].text);
    free(e);
}
bool pe_uses_touch(const pe_engine *e) { return e && e->touch_mode != TM_OFF; }
bool pe_uses_tilt(const pe_engine *e) { return e && e->tilt_on; }
bool pe_uses_gyro(const pe_engine *e) { return e && e->uses_gyro; }

// MARK: Outputs

static void timer_add(pe_engine *e, double at, int kind, int a, int b) {
    if (e->ntimers >= MAX_TIMERS) return;
    e->timers[e->ntimers++] = (timer_t_){ at, kind, a, b };
}
static void timers_cancel(pe_engine *e, int kind, int a) {
    for (int i = 0; i < e->ntimers; i++)
        if (e->timers[i].kind == kind && e->timers[i].a == a) { e->timers[i] = e->timers[--e->ntimers]; i--; }
}

static void emit_axis(pe_engine *e, int axis, int v) {
    if (v < -32768) v = -32768; if (v > 32767) v = 32767;
    if (e->axis_out[axis] == v) return;
    e->axis_out[axis] = v;
    if (e->sink.pad_axis) e->sink.pad_axis(e->sink.ctx, axis, v);
}
static void update_triggers(pe_engine *e);

static bool gyro_enabled(const pe_engine *e);
static int top_layer(const pe_engine *e) {
    for (int l = MAX_LAYERS - 1; l > 0; l--) if (e->layer_holds[l] > 0 || e->layer_toggled[l]) return l;
    return 0;
}
// Tells the sink when the layer or the gyro switch changes (for an on-screen note).
static void report_state(pe_engine *e) {
    int l = top_layer(e), g = e->gyro_out == 0 ? -1 : gyro_enabled(e) ? 1 : 0;
    if (l == e->shown_layer && g == e->shown_gyro) return;
    e->shown_layer = l; e->shown_gyro = g;
    if (e->sink.state) e->sink.state(e->sink.ctx, l, g);
}

static void out_set(pe_engine *e, out_t o, bool down) {
    int d = down ? 1 : -1;
    switch (o.kind) {
    case O_PAD: {
        int r = e->pad_ref[o.code] += d; if (r < 0) e->pad_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.pad_button) e->sink.pad_button(e->sink.ctx, o.code, down);
        break; }
    case O_TRIG: { int r = e->trig_ref[o.code] += d; if (r < 0) e->trig_ref[o.code] = 0; update_triggers(e); break; }
    case O_KEY: {
        int r = e->key_ref[o.code] += d; if (r < 0) e->key_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.key) e->sink.key(e->sink.ctx, o.code, down);
        break; }
    case O_MOUSE: {
        int r = e->mouse_ref[o.code] += d; if (r < 0) e->mouse_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.mouse_button) e->sink.mouse_button(e->sink.ctx, o.code, down);
        break; }
    case O_WHEEL: if (down && e->sink.wheel) e->sink.wheel(e->sink.ctx, o.code); break;
    case O_GYRO_ON: e->gyro_on_holds += d; if (e->gyro_on_holds < 0) e->gyro_on_holds = 0; break;
    case O_GYRO_OFF: e->gyro_off_holds += d; if (e->gyro_off_holds < 0) e->gyro_off_holds = 0; break;
    case O_GYRO_TOGGLE: if (down) e->gyro_toggled = !e->gyro_toggled; break;
    case O_LAYER_HOLD: e->layer_holds[o.code] += d; if (e->layer_holds[o.code] < 0) e->layer_holds[o.code] = 0; break;
    case O_LAYER_TOGGLE: if (down) e->layer_toggled[o.code] = !e->layer_toggled[o.code]; break;
    case O_MACRO:
        if (down && !e->macro_run[o.code] && e->macros[o.code].n) { e->macro_run[o.code] = true; e->macro_pos[o.code] = 0; e->macro_held[o.code].n = 0; run_macro(e, o.code, e->last_tick); }
        break;
    case O_MENU: if (down) menu_begin(e, o.code); else if (e->menu_open == o.code) menu_end(e); break;
    case O_KEYBOARD: if (down && e->sink.menu) e->sink.menu(e->sink.ctx, PE_KEYBOARD_MENU, 1); break;
    case O_CALIBRATE: if (down) pe_calibrate(e, e->last_tick); break;
    case O_RUMBLE: if (down && e->sink.menu) e->sink.menu(e->sink.ctx, PE_RUMBLE_MENU, 1); break;
    default: break;
    }
    if (o.kind == O_LAYER_HOLD || o.kind == O_LAYER_TOGGLE) apply_layers(e);
    if (o.kind >= O_GYRO_ON && o.kind <= O_LAYER_TOGGLE) report_state(e);
}
static void outs_set(pe_engine *e, const outs_t *o, bool down) {
    if (down) for (int i = 0; i < o->n; i++) out_set(e, o->o[i], true);
    else for (int i = o->n - 1; i >= 0; i--) out_set(e, o->o[i], false);
}
// Down now, up after a short pulse (taps). Stored in a timer by value.
static void pulse(pe_engine *e, const outs_t *o, double now) {
    outs_set(e, o, true);
    int slot = -1;
    for (int i = 0; i < MAX_TIMERS; i++) { bool used = false; for (int t = 0; t < e->ntimers; t++) if (e->timers[t].kind == T_RELEASE_OUTS && e->timers[t].a == i) used = true; if (!used) { slot = i; break; } }
    if (slot < 0) { outs_set(e, o, false); return; }
    e->pulse_store[slot] = *o;
    timer_add(e, now + PULSE, T_RELEASE_OUTS, slot, 0);
}

// MARK: Layers and lookup

static bool layer_active(const pe_engine *e, int l) { return l == 0 || e->layer_holds[l] > 0 || e->layer_toggled[l]; }
static const binding_t *lookup(const pe_engine *e, int in) {
    for (int l = MAX_LAYERS - 1; l >= 0; l--) if (layer_active(e, l) && e->bind[l][in].set) return &e->bind[l][in];
    return NULL;
}
static bool trigger_bound(const pe_engine *e, int t) {
    return lookup(e, PE_LT + t) || lookup(e, PE_LT_FULL + t);
}

// MARK: Buttons

static void input_down(pe_engine *e, int in, double now);
static void input_up(pe_engine *e, int in, double now);
// The controller button an input stays when nothing is set for it: the controller's own, and the buttons of a
// device that joins it. -1: nothing.
static int pass_target(const pe_engine *e, int in) {
    if (in < PE_PAD_BUTTONS) return in;
    int slot = dev_slot(in);
    if (slot && e->dev[slot].join && dev_key(in) < PE_PAD_BUTTONS) return dev_key(in);
    return -1;
}

static void begin_press(pe_engine *e, int in, const binding_t *b, double now) {
    press_t *p = &e->press[in];
    // A binding that only has a simultaneous-press part leaves the button as itself otherwise.
    if (b && !b->press.n && !b->tap.n && !b->hold.n && !b->dbl.n) b = NULL;
    p->b = b; p->since = now; p->passthrough = false;
    if (!b) {
        p->phase = P_PRESS; p->passthrough = true;
        int t = pass_target(e, in);
        if (t >= 0) { out_t o = { O_PAD, (short)t }; out_set(e, o, true); }
        return;
    }
    if (b->hold.n || (b->tap.n && b->press.n == 0 && b->dbl.n == 0)) {
        p->phase = P_WAIT_HOLD;
        if (b->press.n) { outs_set(e, &b->press, true); p->active = b->press; } else p->active.n = 0;
        timer_add(e, now + b->hold_time, T_HOLD, in, 0);
        return;
    }
    if (b->dbl.n) {     // tap waits to see if a second press follows
        p->phase = P_WAIT_DOUBLE;
        if (b->press.n) { outs_set(e, &b->press, true); p->active = b->press; } else p->active.n = 0;
        return;
    }
    p->phase = P_PRESS;
    p->active = b->press;
    outs_set(e, &b->press, true);
    if (b->turbo > 0) timer_add(e, now + b->turbo, T_TURBO, in, 1);
}

static void check_sequences(pe_engine *e, int in, double now) {
    if (e->nhist && now - e->hist_t[e->nhist - 1] > 2) e->nhist = 0;
    if (e->nhist == 8) { memmove(e->hist_in, e->hist_in + 1, 7 * sizeof(int)); memmove(e->hist_t, e->hist_t + 1, 7 * sizeof(double)); e->nhist = 7; }
    e->hist_in[e->nhist] = in; e->hist_t[e->nhist] = now; e->nhist++;
    for (int q = 0; q < MAX_SEQS; q++) {
        const seq_t *sq = &e->seqs[q];
        if (sq->n < 2 || sq->n > e->nhist) continue;
        int base = e->nhist - sq->n; bool ok = true;
        for (int i = 0; i < sq->n && ok; i++) {
            if (e->hist_in[base + i] != sq->in[i]) ok = false;
            if (i > 0 && e->hist_t[base + i] - e->hist_t[base + i - 1] > sq->step) ok = false;
        }
        if (ok) { e->nhist = 0; pulse(e, &sq->out, now); return; }
    }
}
static void input_down(pe_engine *e, int in, double now) {
    press_t *p = &e->press[in];
    check_sequences(e, in, now);
    if (p->phase == P_WAIT_DOUBLE && p->b && p->b->dbl.n && now - p->since <= p->b->double_time) {
        // second press: the double binding
        timers_cancel(e, T_DOUBLE_WAIT, in);
        p->phase = P_DOUBLE; p->active = p->b->dbl;
        outs_set(e, &p->b->dbl, true);
        return;
    }
    if (p->phase == P_WAIT_DOUBLE) {     // too late for a double: the pending tap fires first
        timers_cancel(e, T_DOUBLE_WAIT, in);
        if (p->b && p->b->tap.n) pulse(e, &p->b->tap, now);
        p->phase = P_IDLE;
    }
    if (p->phase != P_IDLE) return;
    const binding_t *b = lookup(e, in);
    // Simultaneous press: wait briefly for the partner.
    if (b && b->sim_with >= 0) {
        int partner = b->sim_with;
        press_t *q = &e->press[partner];
        if (q->phase == P_SIM_PENDING && now - q->since <= SIM_WINDOW) {
            timers_cancel(e, T_SIM_WAIT, partner);
            const binding_t *qb = q->b;
            const outs_t *so = b->sim.n ? &b->sim : (qb ? &qb->sim : &b->sim);
            p->phase = P_SIM; q->phase = P_SIM; p->b = b;
            p->active = *so; q->active.n = 0;
            outs_set(e, so, true);
            return;
        }
        p->phase = P_SIM_PENDING; p->b = b; p->since = now;
        timer_add(e, now + SIM_WINDOW, T_SIM_WAIT, in, 0);
        return;
    }
    // A partner may be pending on us even though our own binding doesn't name it.
    for (int other = 0; other < PE_ALL_INPUTS; other++) {
        press_t *q = &e->press[other];
        if (q->phase == P_SIM_PENDING && q->b && q->b->sim_with == in && now - q->since <= SIM_WINDOW) {
            timers_cancel(e, T_SIM_WAIT, other);
            p->phase = P_SIM; q->phase = P_SIM; p->b = b;
            p->active = q->b->sim; q->active.n = 0;
            outs_set(e, &q->b->sim, true);
            return;
        }
    }
    begin_press(e, in, b, now);
}

static void input_up(pe_engine *e, int in, double now) {
    press_t *p = &e->press[in];
    switch (p->phase) {
    case P_IDLE: return;
    case P_SIM_PENDING:                  // released before the partner came: a normal quick press
        timers_cancel(e, T_SIM_WAIT, in);
        p->phase = P_IDLE;
        begin_press(e, in, p->b, now);
        input_up(e, in, now);
        return;
    case P_WAIT_HOLD:
        timers_cancel(e, T_HOLD, in);
        outs_set(e, &p->active, false);
        if (p->b->dbl.n) { p->phase = P_WAIT_DOUBLE; p->since = now; p->active.n = 0; timer_add(e, now + p->b->double_time, T_DOUBLE_WAIT, in, 0); return; }
        if (p->b->tap.n) pulse(e, &p->b->tap, now);
        p->phase = P_IDLE;
        return;
    case P_WAIT_DOUBLE:
        outs_set(e, &p->active, false); p->active.n = 0;
        p->since = now;
        timer_add(e, now + p->b->double_time, T_DOUBLE_WAIT, in, 0);
        return;                          // stays waiting
    default:
        timers_cancel(e, T_TURBO, in);
        if (p->passthrough) { int t = pass_target(e, in); if (t >= 0) { out_t o = { O_PAD, (short)t }; out_set(e, o, false); } }
        else outs_set(e, &p->active, false);
        p->active.n = 0; p->phase = P_IDLE; p->passthrough = false;
        return;
    }
}

// A virtual input (a stick direction, a touchpad zone, a tilt, a device's part) pressed or let go.
static void set_input(pe_engine *e, int in, bool down, double now) {
    if (e->physical[in] == down) return;
    e->physical[in] = down;
    if (down) input_down(e, in, now); else input_up(e, in, now);
}
static int touch_zone_of(double x, double y) { return (x >= 0.5) + 2 * (y >= 0.5); }

void pe_button(pe_engine *e, int button, bool down, double now) {
    if (!e || button < 0 || button >= PE_PAD_BUTTONS) return;
    // With touchpad zones, a click counts as a click in the zone under the finger (when that's set to something).
    if (button == PE_TOUCHPAD && e->touch_mode == TM_ZONES) {
        if (down && e->f_down[0] && e->touch_click_in < 0) {
            int zi = PE_TC1 + touch_zone_of(e->f_x[0], e->f_y[0]);
            if (lookup(e, zi)) { pe_tick(e, now); e->touch_click_in = zi; set_input(e, zi, true, now); return; }
        } else if (!down && e->touch_click_in >= 0) { pe_tick(e, now); set_input(e, e->touch_click_in, false, now); e->touch_click_in = -1; return; }
    }
    if (e->physical[button] == down) return;
    e->physical[button] = down;
    pe_tick(e, now);
    if (down) input_down(e, button, now); else input_up(e, button, now);
}

// MARK: Triggers

// What the devices' axes add to one of the controller's (sticks −1…1 y down, like SDL; triggers 0…1).
static double dev_pad(const pe_engine *e, int target) {
    double sum = 0;
    for (int d = 1; d <= e->ndev; d++) for (int n = 0; n < PE_DEV_AXES; n++) {
        const dev_axis_t *a = &e->dev[d].ax[n];
        if (a->mode == A_PAD && a->to == target) sum += target >= 4 ? fmax(0, a->v) : a->v;
    }
    return sum;
}
static void update_triggers(pe_engine *e) {
    for (int t = 0; t < 2; t++) {
        int v = 0;
        if (e->trig_ref[t] > 0) v = 32767;
        else if (e->trig_mode[t] == 0 && !trigger_bound(e, t)) v = e->raw_axis[PE_AXIS_LT + t];
        if (e->ndev) { int dv = (int)lround(fmin(1, dev_pad(e, 4 + t)) * 32767); if (dv > v) v = dv; }
        emit_axis(e, PE_AXIS_LT + t, v);
    }
}
static void trigger_input(pe_engine *e, int t, double now) {
    double v = e->raw_axis[PE_AXIS_LT + t] / 32767.0;
    int soft = PE_LT + t, full = PE_LT_FULL + t;
    bool sdown = v >= e->trig_soft[t], fdown = v >= e->trig_full[t];
    // Pressing: soft pull, then full. Letting go: full, then soft.
    if (sdown && !e->physical[soft]) { e->physical[soft] = true; input_down(e, soft, now); }
    if (fdown != e->physical[full]) { e->physical[full] = fdown; if (fdown) input_down(e, full, now); else input_up(e, full, now); }
    if (!sdown && e->physical[soft]) { e->physical[soft] = false; input_up(e, soft, now); }
}

// MARK: Sticks

static void stick_shape(const stick_t *k, double x, double y, double *ox, double *oy, double *mag) {
    double m = sqrt(x * x + y * y);
    if (m <= k->dz) { *ox = *oy = 0; *mag = 0; return; }
    double r = (m - k->dz) / (k->outer - k->dz); if (r > 1) r = 1;
    *ox = x / m * r; *oy = y / m * r; *mag = r;
}
static void update_pad_sticks(pe_engine *e) {
    double sx[2] = {0, 0}, sy[2] = {0, 0};
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        if (k->mode != S_PAD) continue;
        double x, y, m; stick_shape(k, k->x, k->y, &x, &y, &m);
        sx[k->to] += x * k->xs; sy[k->to] += (k->invy ? -y : y) * k->ys;
    }
    sx[0] += e->gyro_stick_x * (e->gyro_out == G_LSTICK); sy[0] += e->gyro_stick_y * (e->gyro_out == G_LSTICK);
    sx[1] += e->gyro_stick_x * (e->gyro_out == G_RSTICK); sy[1] += e->gyro_stick_y * (e->gyro_out == G_RSTICK);
    for (int s = 0; s < 2; s++) {
        double dx = e->ndev ? dev_pad(e, 2 * s) : 0, dy = e->ndev ? dev_pad(e, 2 * s + 1) : 0;
        double x = fmax(-1, fmin(1, sx[s] + dx)), y = fmax(-1, fmin(1, -sy[s] + dy));
        emit_axis(e, s ? PE_AXIS_RX : PE_AXIS_LX, (int)lround(x * 32767));
        emit_axis(e, s ? PE_AXIS_RY : PE_AXIS_LY, (int)lround(y * 32767));      // SDL: y down
    }
}
static void mouse_out(pe_engine *e, double dx, double dy) {
    e->m_rest_x += dx; e->m_rest_y += dy;
    int x = (int)e->m_rest_x, y = (int)e->m_rest_y;
    if (!x && !y) return;
    e->m_rest_x -= x; e->m_rest_y -= y;
    if (e->sink.mouse_move) e->sink.mouse_move(e->sink.ctx, x, y);
}
static double wrap180(double a) { while (a > 180) a -= 360; while (a < -180) a += 360; return a; }
static void stick_keys(pe_engine *e, stick_t *k) {
    double m = sqrt(k->x * k->x + k->y * k->y);
    bool want[4] = { false, false, false, false };
    if (m > fmax(k->dz, 0.4)) {
        double a = atan2(k->x, k->y) * 180 / M_PI;        // 0 up, 90 right
        want[0] = fabs(a) < 67.5; want[1] = fabs(a) > 112.5; want[3] = a > 22.5 && a < 157.5; want[2] = a < -22.5 && a > -157.5;
    }
    for (int i = 0; i < 4; i++) if (want[i] != (k->keys_down[i] != 0)) {
        k->keys_down[i] = want[i];
        out_t o = { O_KEY, (short)k->keys[i] }; out_set(e, o, want[i]);
    }
}
// The stick as four buttons (eight ways: up-right holds both), each set like any button.
static void stick_dirs(pe_engine *e, int s, double now) {
    stick_t *k = &e->stick[s];
    double m = sqrt(k->x * k->x + k->y * k->y);
    bool want[4] = { false, false, false, false };       // up, down, left, right
    if (m > fmax(k->dz, 0.4)) {
        double a = atan2(k->x, k->y) * 180 / M_PI;
        want[0] = fabs(a) < 67.5; want[1] = fabs(a) > 112.5; want[3] = a > 22.5 && a < 157.5; want[2] = a < -22.5 && a > -157.5;
    }
    for (int i = 0; i < 4; i++) {
        int in = PE_LS_UP + 4 * s + i;
        if (want[i] != e->physical[in]) { e->physical[in] = want[i]; if (want[i]) input_down(e, in, now); else input_up(e, in, now); }
    }
}
static void stick_flick(pe_engine *e, stick_t *k, double now) {
    double m = sqrt(k->x * k->x + k->y * k->y);
    double a = atan2(k->x, k->y) * 180 / M_PI;
    if (!k->in_flick && m >= 0.9) {
        k->in_flick = true; k->last_angle = a;
        k->flick_left = a / 360.0 * k->flick360;
        k->flick_rate = k->flicktime > 0 ? k->flick_left / k->flicktime : 0;
        if (k->flicktime <= 0) { mouse_out(e, k->flick_left, 0); k->flick_left = 0; }
        k->flicking = k->flick_left != 0;
    } else if (k->in_flick && m < 0.7) {
        k->in_flick = false; k->last_angle = NAN;
    } else if (k->in_flick && m >= 0.7) {
        double d = wrap180(a - k->last_angle);
        k->last_angle = a;
        mouse_out(e, d / 360.0 * k->flick360, 0);
    }
    (void)now;
}
static void devices_continuous(pe_engine *e, double dt) {
    double mx = 0, my = 0;
    for (int d = 1; d <= e->ndev; d++) for (int n = 0; n < PE_DEV_AXES; n++) {
        const dev_axis_t *a = &e->dev[d].ax[n];
        if (a->mode != A_MOUSE || a->v == 0) continue;
        double m = fabs(a->v), speed = a->sens * pow(m, a->power) * dt * (a->v < 0 ? -1 : 1);
        if (a->to == 1) my += speed; else mx += speed;
    }
    if (mx || my) mouse_out(e, mx, my);
}
static void sticks_continuous(pe_engine *e, double dt) {
    if (e->ndev) devices_continuous(e, dt);
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        if (k->mode == S_MOUSE) {
            double x, y, m; stick_shape(k, k->x, k->y, &x, &y, &m);
            if (m >= k->edge && k->ramp > 0) k->ramp_t += dt; else k->ramp_t = 0;
            if (m > 0) {
                double boost = k->ramp > 0 ? 1 + k->ramp * fmin(1, k->ramptime > 0 ? k->ramp_t / k->ramptime : 1) : 1;
                double speed = k->sens * pow(m, k->power) * boost * dt;
                mouse_out(e, x / m * speed * k->xs, -(k->invy ? -y : y) / m * speed * k->ys);
            }
        } else if (k->mode == S_SCROLL) {
            double x, y, m; stick_shape(k, k->x, k->y, &x, &y, &m);
            if (m > 0) {
                e->scroll_rest += (k->invy ? -y : y) / m * k->sens * pow(m, k->power) * dt;
                int n = (int)e->scroll_rest;
                if (n) { e->scroll_rest -= n; if (e->sink.wheel) e->sink.wheel(e->sink.ctx, n); }
            }
        } else if (k->mode == S_FLICK && k->flicking) {
            double step = k->flick_rate * dt;
            if (fabs(step) >= fabs(k->flick_left)) { step = k->flick_left; k->flicking = false; }
            k->flick_left -= step;
            mouse_out(e, step, 0);
        }
    }
}

void pe_axis(pe_engine *e, int axis, int value, double now) {
    if (!e || axis < 0 || axis >= PE_AXES) return;
    pe_tick(e, now);
    e->raw_axis[axis] = value;
    if (axis == PE_AXIS_LT || axis == PE_AXIS_RT) { int t = axis - PE_AXIS_LT; trigger_input(e, t, now); update_triggers(e); return; }
    int s = axis >= PE_AXIS_RX;
    stick_t *k = &e->stick[s];
    k->x = e->raw_axis[s ? PE_AXIS_RX : PE_AXIS_LX] / 32767.0;
    k->y = -e->raw_axis[s ? PE_AXIS_RY : PE_AXIS_LY] / 32767.0;       // y up
    // A radial menu is open on this stick: the stick points at a slice and does nothing else.
    if (e->menu_open >= 0 && e->menus[e->menu_open].stick == s) {
        const menu_t *mn = &e->menus[e->menu_open];
        if (mn->n > 0 && sqrt(k->x * k->x + k->y * k->y) > 0.5) {
            double a = atan2(k->x, k->y) * 180 / M_PI; if (a < 0) a += 360;
            double w = 360.0 / mn->n;
            int sel = (int)floor((a + w / 2) / w) % mn->n;
            if (sel != e->menu_sel) { e->menu_sel = sel; if (e->sink.menu) e->sink.menu(e->sink.ctx, e->menu_open, sel); }
        }
        k->x = k->y = 0;
    }
    if (k->mode == S_KEYS) stick_keys(e, k);
    else if (k->mode == S_DIRS) stick_dirs(e, s, now);
    else if (k->mode == S_FLICK) stick_flick(e, k, now);
    update_pad_sticks(e);
}

// MARK: Gyro

static bool gyro_enabled(const pe_engine *e) {
    if (e->gyro_off_holds > 0) return false;
    if (e->gyro_on_holds > 0) return true;
    return e->gyro_default != e->gyro_toggled;
}

// MARK: Calibration
// The gyro reads a little even lying still (its drift). Put down, it's measured for 1.5 s (after half a second of
// stillness, once per time it's put down); asked for, for 2 s from now. Moving it starts the measurement over.
static void cal_report(pe_engine *e, float p) {
    if (p >= 0 && p < 1 && p - e->cal_shown < 0.05 && p >= e->cal_shown) return;
    e->cal_shown = p;
    if (e->sink.calibration) e->sink.calibration(e->sink.ctx, p);
}
void pe_calibrate(pe_engine *e, double now) {
    if (!e) return;
    e->cal_mode = 2; e->cal_start = now; e->cal_n = 0; e->cal_sum[0] = e->cal_sum[1] = e->cal_sum[2] = 0;
    e->cal_shown = -1; cal_report(e, 0);
}
static void calibration_sample(pe_engine *e, double x, double y, double z, double now) {
    // Still: hardly changing from one reading to the next, and not far off what it reads at rest.
    double d = fabs(x - e->cal_prev[0]) + fabs(y - e->cal_prev[1]) + fabs(z - e->cal_prev[2]);
    double off = sqrt((x - e->cal_x) * (x - e->cal_x) + (y - e->cal_y) * (y - e->cal_y) + (z - e->cal_z) * (z - e->cal_z));
    e->cal_prev[0] = x; e->cal_prev[1] = y; e->cal_prev[2] = z;
    bool still = e->cal_mode == 2 ? d < 6 && off < 40 : d < 1.0 && off < 8;
    if (still) { if (!e->still_since) { e->still_since = now; e->cal_done = false; } }
    else { e->still_since = 0; }
    if (e->cal_mode == 0 && e->g_autocal && still && !e->cal_done && now - e->still_since > 0.5) {
        e->cal_mode = 1; e->cal_start = now; e->cal_n = 0; e->cal_sum[0] = e->cal_sum[1] = e->cal_sum[2] = 0; e->cal_shown = -1;
    }
    if (!e->cal_mode) return;
    if (!still) {
        if (e->cal_mode == 1) { e->cal_mode = 0; if (e->cal_n > 10) cal_report(e, -1); return; }
        e->cal_start = now; e->cal_n = 0; e->cal_sum[0] = e->cal_sum[1] = e->cal_sum[2] = 0;     // asked for: start over
        e->cal_shown = -1; cal_report(e, -1); cal_report(e, 0);
        return;
    }
    e->cal_sum[0] += x; e->cal_sum[1] += y; e->cal_sum[2] += z; e->cal_n++;
    double span = e->cal_mode == 2 ? 2.0 : 1.5, p = (now - e->cal_start) / span;
    if (p >= 1 && e->cal_n >= 20) {
        e->cal_x = e->cal_sum[0] / e->cal_n; e->cal_y = e->cal_sum[1] / e->cal_n; e->cal_z = e->cal_sum[2] / e->cal_n;
        e->cal_mode = 0; e->cal_done = true;
        e->cal_shown = -1; cal_report(e, 1);
    } else cal_report(e, (float)fmin(p, 0.99));
}

void pe_gyro(pe_engine *e, float gx, float gy, float gz, double now) {
    if (!e || e->gyro_out == G_OFF) return;
    pe_tick(e, now);
    double dt = e->last_gyro > 0 ? now - e->last_gyro : 0;
    e->last_gyro = now;
    if (dt <= 0 || dt > 0.1) dt = 0;
    double x = gx * 180 / M_PI, y = gy * 180 / M_PI, z = gz * 180 / M_PI;     // degrees per second
    calibration_sample(e, x, y, z, now);
    x -= e->cal_x; y -= e->cal_y; z -= e->cal_z;
    // A controller lying still still reads a little: below the sensor's noise nothing moves.
    if (fabs(x) < 0.4) x = 0;
    if (fabs(y) < 0.4) y = 0;
    if (fabs(z) < 0.4) z = 0;
    // Right-handed axes (x right, y out of the face, z towards the player), counter-clockwise positive: turning
    // right is −y, tilting right is −z — the same sign, so "both" adds them. Left is +.
    double yaw = y * e->g_yw + z * e->g_rw;
    double ox = -yaw, oy = -x;                       // right +, down + (mouse)
    // One Euro filter: strong smoothing when turning slowly (steady aim), little when fast (no lag on flicks).
    if (e->g_euro && dt > 0) {
        double v[2] = { ox, oy };
        for (int c = 0; c < 2; c++) {
            if (!e->eu_init) { e->eu_x[c] = v[c]; e->eu_dx[c] = 0; e->eu_prev[c] = v[c]; continue; }
            double dtau = 1 / (2 * M_PI * 1.0), ad = 1 / (1 + dtau / dt);
            double d = (v[c] - e->eu_prev[c]) / dt; e->eu_prev[c] = v[c];
            e->eu_dx[c] += ad * (d - e->eu_dx[c]);
            double cut = e->g_mincut + e->g_beta * fabs(e->eu_dx[c]);
            double tau = 1 / (2 * M_PI * fmax(cut, 0.01)), a = 1 / (1 + tau / dt);
            e->eu_x[c] += a * (v[c] - e->eu_x[c]);
            v[c] = e->eu_x[c];
        }
        e->eu_init = true;
        ox = v[0]; oy = v[1];
    }
    if (e->g_invx) ox = -ox;
    if (e->g_invy) oy = -oy;
    double mag = sqrt(ox * ox + oy * oy);
    // Smoothing for small movements (steadier aim), full response for big ones.
    if (e->g_smooth > 0) {
        e->smooth_buf[e->smooth_i][0] = ox; e->smooth_buf[e->smooth_i][1] = oy; e->smooth_i = (e->smooth_i + 1) % 16;
        double ax = 0, ay = 0; for (int i = 0; i < 16; i++) { ax += e->smooth_buf[i][0]; ay += e->smooth_buf[i][1]; }
        ax /= 16; ay /= 16;
        double w = mag >= 2 * e->g_smooth ? 1 : mag <= e->g_smooth ? 0 : (mag - e->g_smooth) / e->g_smooth;
        ox = ox * w + ax * (1 - w); oy = oy * w + ay * (1 - w);
        mag = sqrt(ox * ox + oy * oy);
    }
    // Tightening: very small movements are hand shake, scale them down.
    if (e->g_tight > 0 && mag < e->g_tight && mag > 0) { double f = mag / e->g_tight; ox *= f; oy *= f; mag *= f; }
    bool on = gyro_enabled(e);
    if (e->gyro_out == G_MOUSE) {
        if (!on || dt == 0) return;
        double sens = e->g_min;
        if (e->g_max != e->g_min && e->g_hi > e->g_lo) {
            double f = (mag - e->g_lo) / (e->g_hi - e->g_lo); f = fmax(0, fmin(1, f));
            sens = e->g_min + (e->g_max - e->g_min) * f;
        }
        mouse_out(e, ox * sens * dt * e->g_xs, oy * sens * dt * e->g_ys);
    } else {
        double sx = 0, sy = 0;
        if (on && mag > 0) {
            double r = mag / e->g_stickfull; if (r > 1) r = 1;
            double out = e->g_stickmin + (1 - e->g_stickmin) * r;
            sx = ox / mag * out * (mag > 0.5) * e->g_xs; sy = -oy / mag * out * (mag > 0.5) * e->g_ys;
        }
        e->gyro_stick_x = sx; e->gyro_stick_y = sy;
        update_pad_sticks(e);
    }
}

// MARK: Timers

void pe_tick(pe_engine *e, double now) {
    if (!e) return;
    double dt = e->last_tick > 0 ? now - e->last_tick : 0;
    if (dt > 0.1) dt = 0.1;
    if (dt > 0) sticks_continuous(e, dt);
    e->last_tick = now;
    bool again = true;
    while (again) {
        again = false;
        for (int i = 0; i < e->ntimers; i++) {
            if (e->timers[i].at > now) continue;
            timer_t_ t = e->timers[i];
            e->timers[i] = e->timers[--e->ntimers];
            again = true;
            press_t *p = t.kind == T_RELEASE_OUTS || t.kind == T_MACRO ? NULL : &e->press[t.a];
            switch (t.kind) {
            case T_RELEASE_OUTS: outs_set(e, &e->pulse_store[t.a], false); break;
            case T_HOLD:
                if (p->phase == P_WAIT_HOLD) {
                    p->phase = P_HOLDING;
                    outs_set(e, &p->active, false);
                    p->active = p->b->hold;
                    outs_set(e, &p->b->hold, true);
                }
                break;
            case T_DOUBLE_WAIT:
                if (p->phase == P_WAIT_DOUBLE) {
                    p->phase = P_IDLE;
                    if (p->b->tap.n) pulse(e, &p->b->tap, t.at);
                    else if (!p->b->press.n && e->physical[t.a]) begin_press(e, t.a, NULL, t.at);
                }
                break;
            case T_TURBO:
                if (p->phase == P_PRESS && p->b && p->b->turbo > 0) {
                    bool down = t.b == 0;
                    outs_set(e, &p->active, down);
                    timer_add(e, t.at + p->b->turbo / 2, T_TURBO, t.a, down ? 1 : 0);
                }
                break;
            case T_SIM_WAIT:
                if (p->phase == P_SIM_PENDING) { p->phase = P_IDLE; begin_press(e, t.a, p->b, t.at); }
                break;
            case T_MACRO: run_macro(e, t.a, t.at); break;
            }
            break;
        }
    }
}

double pe_next_deadline(const pe_engine *e) {
    if (!e) return 0;
    double d = 0;
    for (int i = 0; i < e->ntimers; i++) if (!d || e->timers[i].at < d) d = e->timers[i].at;
    bool continuous = false;
    for (int s = 0; s < 2; s++) {
        const stick_t *k = &e->stick[s];
        if (k->mode == S_MOUSE && sqrt(k->x * k->x + k->y * k->y) > k->dz) continuous = true;
        if (k->mode == S_FLICK && k->flicking) continuous = true;
        if (k->mode == S_SCROLL && sqrt(k->x * k->x + k->y * k->y) > k->dz) continuous = true;
    }
    for (int dv = 1; dv <= e->ndev; dv++) for (int n = 0; n < PE_DEV_AXES; n++)
        if (e->dev[dv].ax[n].mode == A_MOUSE && e->dev[dv].ax[n].v != 0) continuous = true;
    if (continuous) { double c = e->last_tick + 0.004; if (!d || c < d) d = c; }
    return d;
}

void pe_release_all(pe_engine *e, double now) {
    if (!e) return;
    for (int i = 0; i < PE_ALL_INPUTS; i++) if (e->physical[i] || e->press[i].phase != P_IDLE) {
        e->physical[i] = false;
        press_t *p = &e->press[i];
        int t = p->passthrough ? pass_target(e, i) : -1;
        if (t >= 0) { out_t o = { O_PAD, (short)t }; out_set(e, o, false); }
        else outs_set(e, &p->active, false);
        p->active.n = 0; p->phase = P_IDLE; p->passthrough = false;
    }
    for (int i = 0; i < e->ntimers; i++) if (e->timers[i].kind == T_RELEASE_OUTS) outs_set(e, &e->pulse_store[e->timers[i].a], false);
    e->ntimers = 0;
    for (int m = 0; m < MAX_MACROS; m++) if (e->macro_run[m]) { outs_set(e, &e->macro_held[m], false); e->macro_held[m].n = 0; e->macro_run[m] = false; }
    if (e->menu_open >= 0) { int n = e->menu_open; e->menu_open = -1; e->menu_sel = -1; if (e->sink.menu) e->sink.menu(e->sink.ctx, n, -2); }
    e->f_down[0] = e->f_down[1] = false; e->touch_zone = -1; e->touch_click_in = -1; e->nhist = 0;
    for (int s = 0; s < 2; s++) { stick_t *k = &e->stick[s]; k->x = k->y = 0; if (k->mode == S_KEYS) stick_keys(e, k); k->in_flick = k->flicking = false; }
    for (int a = 0; a < PE_AXES; a++) e->raw_axis[a] = 0;
    e->gyro_stick_x = e->gyro_stick_y = 0;
    for (int d = 1; d <= PE_MAX_DEVICES; d++) { e->dev[d].hat = 0; for (int n = 0; n < PE_DEV_AXES; n++) { e->dev[d].ax[n].v = 0; e->dev[d].ax[n].pos = e->dev[d].ax[n].neg = false; } }
    for (int b = 0; b < PE_PAD_BUTTONS; b++) if (e->pad_ref[b]) { e->pad_ref[b] = 1; out_t o = { O_PAD, (short)b }; out_set(e, o, false); }
    for (int k = 0; k < KEYS; k++) if (e->key_ref[k]) { e->key_ref[k] = 1; out_t o = { O_KEY, (short)k }; out_set(e, o, false); }
    for (int m = 0; m < PE_MOUSE_BUTTONS; m++) if (e->mouse_ref[m]) { e->mouse_ref[m] = 1; out_t o = { O_MOUSE, (short)m }; out_set(e, o, false); }
    e->trig_ref[0] = e->trig_ref[1] = 0;
    memset(e->layer_holds, 0, sizeof e->layer_holds);
    memset(e->layer_toggled, 0, sizeof e->layer_toggled);
    e->gyro_on_holds = e->gyro_off_holds = 0;
    apply_layers(e);
    update_triggers(e);
    update_pad_sticks(e);
    report_state(e);
    (void)now;
}

// MARK: Extra devices

static void dev_input(pe_engine *e, int in, bool down, double now) { set_input(e, in, down, now); }
void pe_dev_button(pe_engine *e, int slot, int button, bool down, double now) {
    if (!e || slot < 1 || slot > PE_MAX_DEVICES || button < 0 || button >= PE_DEV_BUTTONS) return;
    pe_tick(e, now);
    dev_input(e, dev_in(slot, button), down, now);
}
void pe_dev_hat(pe_engine *e, int slot, int bits, double now) {
    if (!e || slot < 1 || slot > PE_MAX_DEVICES) return;
    pe_tick(e, now);
    e->dev[slot].hat = bits;
    static const int bit[4] = { PE_HAT_UP, PE_HAT_RIGHT, PE_HAT_DOWN, PE_HAT_LEFT };
    // Let go first, then press (sliding from up to right releases up before right goes down).
    for (int h = 0; h < 4; h++) if (!(bits & bit[h])) dev_input(e, dev_in(slot, K_HAT + h), false, now);
    for (int h = 0; h < 4; h++) if (bits & bit[h]) dev_input(e, dev_in(slot, K_HAT + h), true, now);
}
void pe_dev_axis(pe_engine *e, int slot, int axis, int value, double now) {
    if (!e || slot < 1 || slot > PE_MAX_DEVICES || axis < 0 || axis >= PE_DEV_AXES) return;
    pe_tick(e, now);
    dev_axis_t *a = &e->dev[slot].ax[axis];
    double v = fmax(-1, fmin(1, value / 32767.0));
    if (a->inv) v = -v;
    if (a->half) v = (v + 1) / 2;
    double m = fabs(v);
    v = m <= a->dz ? 0 : (v < 0 ? -1 : 1) * fmin(1, (m - a->dz) / (1 - a->dz));
    a->v = v;
    // Past the press point counts as a button press (a little lower to let go, so it doesn't flicker).
    double on = a->press, off = a->press * 0.8;
    bool pos = a->pos ? v > off : v >= on, neg = a->half ? false : a->neg ? v < -off : v <= -on;
    if (pos != a->pos) { a->pos = pos; dev_input(e, dev_in(slot, K_AXIS + 2 * axis), pos, now); }
    if (neg != a->neg) { a->neg = neg; dev_input(e, dev_in(slot, K_AXIS + 2 * axis + 1), neg, now); }
    if (a->mode == A_PAD) { if (a->to >= 4) update_triggers(e); else update_pad_sticks(e); }
}
int pe_device_count(const pe_engine *e) { return e ? e->ndev : 0; }
bool pe_device_info(const pe_engine *e, int slot, int *vendor, int *product, int *nth, bool *gamepad, bool *joined) {
    if (!e || slot < 1 || slot > PE_MAX_DEVICES || !e->dev[slot].set) return false;
    const device_t *v = &e->dev[slot];
    if (vendor) *vendor = v->vendor;
    if (product) *product = v->product;
    if (nth) *nth = v->nth;
    if (gamepad) *gamepad = v->gamepad;
    if (joined) *joined = v->join;
    return true;
}
static bool bound_anywhere(const pe_engine *e, int in) {
    for (int l = 0; l < MAX_LAYERS; l++) if (e->bind[l][in].set) return true;
    return false;
}
bool pe_dev_uses(const pe_engine *e, int slot, int kind, int n) {
    if (!e || slot < 1 || slot > PE_MAX_DEVICES || !e->dev[slot].set) return false;
    if (e->dev[slot].join) return true;
    if (kind == 0) return n >= 0 && n < PE_DEV_BUTTONS && bound_anywhere(e, dev_in(slot, n));
    if (kind == 1) { for (int h = 0; h < 4; h++) if (bound_anywhere(e, dev_in(slot, K_HAT + h))) return true; return false; }
    if (kind == 2 && n >= 0 && n < PE_DEV_AXES)
        return e->dev[slot].ax[n].mode != A_OFF || bound_anywhere(e, dev_in(slot, K_AXIS + 2 * n)) || bound_anywhere(e, dev_in(slot, K_AXIS + 2 * n + 1));
    return false;
}

// MARK: Layers' own stick and gyro settings

static void stick_mode_update(pe_engine *e, int s) {
    stick_t *k = &e->stick[s];
    if (k->mode == S_KEYS) stick_keys(e, k); else if (k->mode == S_DIRS) stick_dirs(e, s, e->last_tick);
}
static void apply_layers(pe_engine *e) {
    for (int s = 0; s < 2; s++) {
        int L = 0;
        for (int l = MAX_LAYERS - 1; l > 0; l--) if (layer_active(e, l) && e->stick_has[l][s]) { L = l; break; }
        if (L == e->stick_layer[s]) continue;
        stick_t *k = &e->stick[s];
        double x = k->x, y = k->y;
        k->x = k->y = 0; stick_mode_update(e, s);            // let go of what the old setting holds
        stick_t n = e->stick_cfg[L][s];
        n.x = x; n.y = y; n.flicking = n.in_flick = false; n.last_angle = NAN; n.rest_x = n.rest_y = 0; n.ramp_t = 0;
        memset(n.keys_down, 0, sizeof n.keys_down);
        *k = n; e->stick_layer[s] = L;
        stick_mode_update(e, s);
    }
    int G = 0;
    for (int l = MAX_LAYERS - 1; l > 0; l--) if (layer_active(e, l) && e->gyro_has[l]) { G = l; break; }
    if (G != e->gyro_layer) { load_gyro(e, &e->gyro_cfg[G]); e->gyro_layer = G; e->gyro_stick_x = e->gyro_stick_y = 0; e->eu_init = false; }
    update_pad_sticks(e);
}

// MARK: Macros

static void run_macro(pe_engine *e, int n, double now) {
    if (n < 0 || n >= MAX_MACROS || !e->macro_run[n]) return;
    macro_t *m = &e->macros[n];
    outs_t *held = &e->macro_held[n];
    while (e->macro_pos[n] < m->n) {
        const mstep_t *st = &m->step[e->macro_pos[n]++];
        switch (st->kind) {
        case MS_DOWN:
            if (st->o.kind == O_MACRO) break;                 // no macros inside macros
            out_set(e, st->o, true);
            if (held->n < MAX_OUTS) held->o[held->n++] = st->o;
            break;
        case MS_UP:
            for (int i = 0; i < held->n; i++) if (held->o[i].kind == st->o.kind && held->o[i].code == st->o.code) {
                out_set(e, st->o, false); held->o[i] = held->o[--held->n]; break;
            }
            break;
        case MS_WAIT: timer_add(e, now + st->ms / 1000.0, T_MACRO, n, 0); return;
        case MS_TEXT: if (st->text && e->sink.text) e->sink.text(e->sink.ctx, st->text); break;
        }
    }
    outs_set(e, held, false); held->n = 0;                   // nothing stays held after a macro
    e->macro_run[n] = false;
}

// MARK: Radial menus

static void menu_begin(pe_engine *e, int n) {
    if (n < 0 || n >= MAX_MENUS || !e->menus[n].set || e->menu_open >= 0) return;
    e->menu_open = n; e->menu_sel = -1;
    int s = e->menus[n].stick;
    stick_t *k = &e->stick[s]; k->x = k->y = 0; stick_mode_update(e, s); update_pad_sticks(e);
    if (e->sink.menu) e->sink.menu(e->sink.ctx, n, -1);
}
static void menu_end(pe_engine *e) {
    int n = e->menu_open, sel = e->menu_sel;
    if (n < 0) return;
    e->menu_open = -1; e->menu_sel = -1;
    if (e->sink.menu) e->sink.menu(e->sink.ctx, n, -2);
    if (sel >= 0 && sel < e->menus[n].n) pulse(e, &e->menus[n].slice[sel], e->last_tick);
    // The stick goes back to what it does, where it is now.
    int s = e->menus[n].stick;
    stick_t *k = &e->stick[s];
    k->x = e->raw_axis[s ? PE_AXIS_RX : PE_AXIS_LX] / 32767.0; k->y = -e->raw_axis[s ? PE_AXIS_RY : PE_AXIS_LY] / 32767.0;
    stick_mode_update(e, s); update_pad_sticks(e);
}

// MARK: Touchpad

void pe_touch(pe_engine *e, int f, bool down, float fx, float fy, double now) {
    if (!e || f < 0 || f > 1 || e->touch_mode == TM_OFF) return;
    pe_tick(e, now);
    bool was = e->f_down[f]; double px = e->f_x[f], py = e->f_y[f];
    double x = fmin(1, fmax(0, fx)), y = fmin(1, fmax(0, fy));
    e->f_down[f] = down;
    if (down) { e->f_x[f] = x; e->f_y[f] = y; }
    double dx = down && was ? x - px : 0, dy = down && was ? y - py : 0;
    switch (e->touch_mode) {
    case TM_MOUSE:
        if (f != 0 || (!dx && !dy)) break;
        // The pad is about twice as wide as it's tall: the same finger movement, the same pointer movement.
        if (e->f_down[1]) goto scroll;
        mouse_out(e, dx * e->touch_sens, dy * e->touch_sens * 0.5);
        break;
    case TM_SCROLL:
        if (f != 0 || !dy) break;
    scroll:
        // Finger up moves the page up (scrolls down), like a Mac trackpad: wheel −.
        e->scroll_rest += dy * e->touch_scroll;
        { int n = (int)e->scroll_rest; if (n) { e->scroll_rest -= n; if (e->sink.wheel) e->sink.wheel(e->sink.ctx, n); } }
        break;
    case TM_ZONES:
        if (f != 0) break;
        {
            int z = down ? touch_zone_of(x, y) : -1;
            if (z != e->touch_zone) {
                if (e->touch_zone >= 0) set_input(e, PE_TZ1 + e->touch_zone, false, now);
                e->touch_zone = z;
                if (z >= 0) set_input(e, PE_TZ1 + z, true, now);
            }
        }
        break;
    }
}

// MARK: Tilt

void pe_accel(pe_engine *e, float ax, float ay, float az, double now) {
    if (!e || !e->tilt_on) return;
    pe_tick(e, now);
    double g = sqrt(ax * ax + ay * ay + az * az);
    if (g <= 0) return;
    double roll = atan2(ax, ay) * 180 / M_PI, pitch = atan2(az, ay) * 180 / M_PI;
    if (e->tilt_invx) roll = -roll;
    // Forward and back count from how you usually hold it: learned while it's held still.
    if (!e->pitch_init) { e->pitch_neutral = pitch; e->pitch_init = true; }
    else if (e->still_since && now - e->still_since > 1) e->pitch_neutral += (pitch - e->pitch_neutral) * 0.02;
    double p = pitch - e->pitch_neutral;
    if (e->tilt_invy) p = -p;
    double on = e->tilt_angle, off = e->tilt_angle * 0.7;
    bool r = e->physical[PE_TILT_RIGHT] ? roll > off : roll > on, l = e->physical[PE_TILT_LEFT] ? roll < -off : roll < -on;
    bool fw = e->physical[PE_TILT_FWD] ? p > off : p > on, bk = e->physical[PE_TILT_BACK] ? p < -off : p < -on;
    set_input(e, PE_TILT_RIGHT, r, now); set_input(e, PE_TILT_LEFT, l, now);
    set_input(e, PE_TILT_FWD, fw, now); set_input(e, PE_TILT_BACK, bk, now);
}
