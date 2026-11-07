// Controller remapping engine: physical controller in (buttons, sticks, triggers, gyro), remapped controller,
// keys and mouse out. Plain C with no system dependencies: it runs inside Wine's controller driver process and
// in Nokcandu's tests. Profiles come in as text (see padengine.c, "Profile text").
#ifndef NOKCANDU_PADENGINE_H
#define NOKCANDU_PADENGINE_H
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Inputs 0…20 are SDL2's game controller buttons; the rest are the triggers as buttons.
enum {
    PE_A, PE_B, PE_X, PE_Y, PE_BACK, PE_GUIDE, PE_START, PE_LS, PE_RS, PE_LB, PE_RB,
    PE_UP, PE_DOWN, PE_LEFT, PE_RIGHT, PE_MISC, PE_PADDLE1, PE_PADDLE2, PE_PADDLE3, PE_PADDLE4, PE_TOUCHPAD,
    PE_PAD_BUTTONS,                         // 21
    PE_LT = PE_PAD_BUTTONS, PE_RT, PE_LT_FULL, PE_RT_FULL,
    PE_INPUTS                               // 25
};
// Axes: SDL2's order. Sticks -32768…32767 (y down), triggers 0…32767.
enum { PE_AXIS_LX, PE_AXIS_LY, PE_AXIS_RX, PE_AXIS_RY, PE_AXIS_LT, PE_AXIS_RT, PE_AXES };
enum { PE_MOUSE_LEFT, PE_MOUSE_RIGHT, PE_MOUSE_MIDDLE, PE_MOUSE_BACK, PE_MOUSE_FORWARD, PE_MOUSE_BUTTONS };

typedef struct {
    void *ctx;
    void (*pad_button)(void *ctx, int button, bool down);
    void (*pad_axis)(void *ctx, int axis, int value);
    void (*key)(void *ctx, int mac_keycode, bool down);
    void (*mouse_button)(void *ctx, int button, bool down);
    void (*mouse_move)(void *ctx, int dx, int dy);
    void (*wheel)(void *ctx, int clicks);           // + up, − down
} pe_sink;

typedef struct pe_engine pe_engine;

/// NULL when the text isn't a profile. Unknown words are skipped, so older engines read newer profiles.
pe_engine *pe_create(const char *profile_text, pe_sink sink);
void pe_destroy(pe_engine *e);
/// Releases everything the engine is holding down (keys, mouse buttons, controller buttons) and centres the sticks.
void pe_release_all(pe_engine *e, double now);

void pe_button(pe_engine *e, int button, bool down, double now);     // SDL button numbers (0…20)
void pe_axis(pe_engine *e, int axis, int value, double now);
/// Gyro in radians per second, SDL's axes: x pitch (up +), y yaw (left +), z roll.
void pe_gyro(pe_engine *e, float x, float y, float z, double now);
/// Timers (tap/hold, turbo, mouse sticks, flicks). Call by pe_next_deadline, or every few milliseconds.
void pe_tick(pe_engine *e, double now);
/// The next time pe_tick has something to do; 0 when nothing is pending.
double pe_next_deadline(const pe_engine *e);
/// Whether the engine wants gyro data (some binding or setting uses it).
bool pe_uses_gyro(const pe_engine *e);

/// Input name ("a", "lb", "ltfull"…) ↔ number; -1 when unknown.
int pe_input_named(const char *name);
const char *pe_input_name(int input);

#ifdef __cplusplus
}
#endif
#endif
