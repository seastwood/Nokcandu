/* Drives Engine/controller-hid/controller-emulation.h (and the shared core it builds in) the way SDL's HIDAPI
 * Switch and PS4 drivers do, with stand-ins for
 * the few Wine and SDL pieces it uses. Prints each report it sends as hex, one per line. */
#include <SDL.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

typedef unsigned short USHORT; typedef unsigned char BYTE; typedef unsigned int UINT; typedef int BOOL; typedef uint64_t UINT64; typedef long NTSTATUS;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_BUFFER_TOO_SMALL 0xC0000023L
#define STATUS_NOT_SUPPORTED 0xC00000BBL
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define CONTAINING_RECORD(address, type, field) ((type *)((char *)(address) - offsetof(type, field)))
#define TRACE(...) do {} while (0)
struct list { struct list *next, *prev; };
#define LIST_INIT(l) { &(l), &(l) }
static void list_add_tail(struct list *l, struct list *e) { e->next = l; e->prev = l->prev; l->prev->next = e; l->prev = e; }
static void list_remove(struct list *e) { e->next->prev = e->prev; e->prev->next = e->next; }
#define LIST_FOR_EACH_ENTRY(e, l, type, field) for ((e) = CONTAINING_RECORD((l)->next, type, field); &(e)->field != (l); (e) = CONTAINING_RECORD((e)->field.next, type, field))
typedef struct { BYTE *reportBuffer; UINT reportBufferLen; BYTE reportId; } HID_XFER_PACKET;
typedef struct { NTSTATUS Status; uint64_t Information; } IO_STATUS_BLOCK;
struct unix_device { const void *vtbl; };
struct device_desc { UINT vid, pid, version, input, uid, bus_type; BOOL is_gamepad, is_hidraw; wchar_t manufacturer[260], product[260], serialnumber[260]; };
struct raw_device_vtbl {
    void (*destroy)(struct unix_device *); NTSTATUS (*start)(struct unix_device *); void (*stop)(struct unix_device *);
    NTSTATUS (*get_report_descriptor)(struct unix_device *, BYTE *, UINT, UINT *);
    void (*set_output_report)(struct unix_device *, HID_XFER_PACKET *, IO_STATUS_BLOCK *);
    void (*get_feature_report)(struct unix_device *, HID_XFER_PACKET *, IO_STATUS_BLOCK *);
    void (*set_feature_report)(struct unix_device *, HID_XFER_PACKET *, IO_STATUS_BLOCK *);
};
static pthread_mutex_t sdl_cs = PTHREAD_MUTEX_INITIALIZER;
static struct list event_queue = LIST_INIT(event_queue);
static void *sdl_handle;
static struct unix_device *created;
static int (*pSDL_JoystickRumble)(SDL_Joystick *, Uint16, Uint16, Uint32);
static Sint16 fake_axes[SDL_CONTROLLER_AXIS_MAX];
static Sint16 fake_get_axis(SDL_GameController *c, SDL_GameControllerAxis a) { return fake_axes[a]; }
static Sint16 (*pSDL_GameControllerGetAxis)(SDL_GameController *, SDL_GameControllerAxis) = fake_get_axis;
static void fake_close_c(SDL_GameController *c) {}
static void fake_close_j(SDL_Joystick *j) {}
static void (*pSDL_GameControllerClose)(SDL_GameController *) = fake_close_c;
static void (*pSDL_JoystickClose)(SDL_Joystick *) = fake_close_j;
static int rumble_low = -1, rumble_high = -1;
static int fake_rumble(SDL_Joystick *j, Uint16 lo, Uint16 hi, Uint32 ms) { rumble_low = lo; rumble_high = hi; return 0; }
static void *raw_device_create(const struct raw_device_vtbl *vtbl, size_t size) { struct unix_device *d = calloc(1, size); d->vtbl = vtbl; return d; }
static void ntdll_umbstowcs(const char *s, size_t n, wchar_t *out, size_t cap) { for (size_t i = 0; i < n && i < cap; i++) out[i] = (unsigned char)s[i]; }
static void bus_event_queue_device_created(struct list *q, struct unix_device *d, struct device_desc *desc) { created = d; }
static void bus_event_queue_device_removed(struct list *q, struct unix_device *d) { printf("removed\n"); }
static int bus_event_queue_input_report(struct list *q, struct unix_device *d, BYTE *r, UINT n) {
    for (UINT i = 0; i < n; i++) printf("%02x", r[i]);
    printf("\n"); return 1;
}
static int mode = 3;
int nokcandu_presented_controller(void *j) { return mode; }

#include "controller-emulation.h"

static void out(BYTE *d, UINT n) {
    HID_XFER_PACKET p = { d, n, d[0] }; IO_STATUS_BLOCK io;
    ((const struct raw_device_vtbl *)created->vtbl)->set_output_report(created, &p, &io);
    if (io.Status != 0 || io.Information != n) printf("bad io\n");
}

static int ds4(void);
int main(int argc, char **argv) {
    pSDL_JoystickRumble = fake_rumble;
    if (argc > 1 && !strcmp(argv[1], "ds4")) { mode = 2; return ds4(); }
    struct device_desc desc = {0};
    fake_axes[SDL_CONTROLLER_AXIS_LEFTX] = 32767; fake_axes[SDL_CONTROLLER_AXIS_LEFTY] = -32768;
    if (!nk_pad_add((SDL_Joystick *)1, (SDL_GameController *)1, 7, &desc)) { printf("not added\n"); return 1; }
    printf("desc %04x:%04x gamepad=%d hidraw=%d\n", desc.vid, desc.pid, desc.is_gamepad, desc.is_hidraw);
    const struct raw_device_vtbl *v = created->vtbl;
    BYTE buf[512]; UINT len = 0;
    v->get_report_descriptor(created, buf, sizeof buf, &len);
    printf("descriptor %u\n", len);
    v->start(created);
    /* SDL's USB start-up: status, handshake, high speed, handshake, USB only. */
    BYTE c1[64] = {0x80, 0x01}; out(c1, 64);
    BYTE c2[64] = {0x80, 0x02}; out(c2, 64);
    BYTE c3[64] = {0x80, 0x03}; out(c3, 64);
    BYTE c4[64] = {0x80, 0x04}; out(c4, 64);
    /* Subcommands: device info, SPI reads of stick and IMU calibration, report mode, IMU on, rumble. */
    BYTE s1[49] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x02}; out(s1, 49);
    BYTE s2[49] = {0x01, 0x01, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x10, 0x3d, 0x60, 0x00, 0x00, 0x12}; out(s2, 49);
    BYTE s3[49] = {0x01, 0x02, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x10, 0x20, 0x60, 0x00, 0x00, 0x18}; out(s3, 49);
    BYTE s4[49] = {0x01, 0x03, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30}; out(s4, 49);
    BYTE s5[49] = {0x01, 0x04, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01}; out(s5, 49);
    BYTE r1[49] = {0x10, 0x05, 0x00, 0x01, 0x40, 0x7f, 0x00, 0x01, 0x40, 0x40}; out(r1, 49);
    printf("rumble %d %d\n", rumble_low, rumble_high);
    /* Press SDL's south button (the Pro's B) and the d-pad up, then move the right stick. */
    SDL_Event e = {0};
    e.type = SDL_CONTROLLERBUTTONDOWN; e.cbutton.which = 7; e.cbutton.button = SDL_CONTROLLER_BUTTON_A; e.cbutton.state = 1;
    pthread_mutex_lock(&sdl_cs); printf("handled %d\n", nk_pad_event(&e));
    e.cbutton.button = SDL_CONTROLLER_BUTTON_DPAD_UP; nk_pad_event(&e);
    SDL_Event a = {0}; a.type = SDL_CONTROLLERAXISMOTION; a.caxis.which = 7; a.caxis.axis = SDL_CONTROLLER_AXIS_TRIGGERRIGHT; a.caxis.value = 30000;
    nk_pad_event(&a);
    SDL_Event other = {0}; other.type = SDL_CONTROLLERBUTTONDOWN; other.cbutton.which = 99;
    printf("other %d\n", nk_pad_event(&other));
    pthread_mutex_unlock(&sdl_cs);
    usleep(12000);                                   /* the next periodic report carries the trigger */
    nk_pad_tick();
    return 0;
}

static void feature(BYTE id, UINT size) {
    BYTE buf[64] = {id}; HID_XFER_PACKET p = { buf, size, id }; IO_STATUS_BLOCK io;
    ((const struct raw_device_vtbl *)created->vtbl)->get_feature_report(created, &p, &io);
    printf("feature %02x status %ld size %lu ", id, (long)io.Status, (unsigned long)io.Information);
    for (UINT i = 0; i < io.Information; i++) printf("%02x", buf[i]);
    printf("\n");
}

static int ds4(void) {
    struct device_desc desc = {0};
    fake_axes[SDL_CONTROLLER_AXIS_LEFTX] = 32767;
    if (!nk_pad_add((SDL_Joystick *)1, (SDL_GameController *)1, 5, &desc)) { printf("not added\n"); return 1; }
    printf("desc %04x:%04x gamepad=%d hidraw=%d\n", desc.vid, desc.pid, desc.is_gamepad, desc.is_hidraw);
    const struct raw_device_vtbl *v = created->vtbl;
    BYTE buf[512]; UINT len = 0;
    v->get_report_descriptor(created, buf, sizeof buf, &len);
    printf("descriptor %u\n", len);
    v->start(created);
    feature(0x02, 37); feature(0x12, 16); feature(0xa3, 49); feature(0x81, 7);
    BYTE out5[32] = {0x05, 0x07, 0x00, 0x00, 0x40, 0xc0, 0x10, 0x20, 0x30};
    HID_XFER_PACKET p = { out5, 32, 5 }; IO_STATUS_BLOCK io; v->set_output_report(created, &p, &io);
    printf("rumble %d %d\n", rumble_low, rumble_high);
    pthread_mutex_lock(&sdl_cs);
    SDL_Event e = {0};
    e.type = SDL_CONTROLLERBUTTONDOWN; e.cbutton.which = 5; e.cbutton.button = SDL_CONTROLLER_BUTTON_A; e.cbutton.state = 1; nk_pad_event(&e);
    e.cbutton.button = SDL_CONTROLLER_BUTTON_DPAD_UP; nk_pad_event(&e);
    SDL_Event a = {0}; a.type = SDL_CONTROLLERAXISMOTION; a.caxis.which = 5; a.caxis.axis = SDL_CONTROLLER_AXIS_TRIGGERRIGHT; a.caxis.value = 32767; nk_pad_event(&a);
    SDL_Event t = {0}; t.type = SDL_CONTROLLERTOUCHPADDOWN; t.ctouchpad.which = 5; t.ctouchpad.finger = 0; t.ctouchpad.x = 0.5f; t.ctouchpad.y = 0.5f;
    printf("touch handled %d\n", nk_pad_event(&t));
    pthread_mutex_unlock(&sdl_cs);
    usleep(6000);
    nk_pad_tick();
    return 0;
}
