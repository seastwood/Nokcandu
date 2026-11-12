// Controller remapping engine: physical controller in (buttons, sticks, triggers, gyro), remapped controller,
// keys and mouse out. Plain C with no system dependencies: it runs inside Wine's controller driver process and
// in Nokcandu's tests. Profiles come in as text (see padengine.c, "Profile text").
#ifndef NOKCANDU_PADENGINE_H
#define NOKCANDU_PADENGINE_H
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Inputs 0…20 are SDL2's game controller buttons; then the triggers as buttons, and the sticks' directions.
enum {
    PE_A, PE_B, PE_X, PE_Y, PE_BACK, PE_GUIDE, PE_START, PE_LS, PE_RS, PE_LB, PE_RB,
    PE_UP, PE_DOWN, PE_LEFT, PE_RIGHT, PE_MISC, PE_PADDLE1, PE_PADDLE2, PE_PADDLE3, PE_PADDLE4, PE_TOUCHPAD,
    PE_PAD_BUTTONS,                         // 21
    PE_LT = PE_PAD_BUTTONS, PE_RT, PE_LT_FULL, PE_RT_FULL,
    // A stick's four directions, when the stick is set to work as them ("stick N mode=dirs").
    PE_LS_UP, PE_LS_DOWN, PE_LS_LEFT, PE_LS_RIGHT, PE_RS_UP, PE_RS_DOWN, PE_RS_LEFT, PE_RS_RIGHT,
    // The touchpad's four zones (top left, top right, bottom left, bottom right): touched, and clicked.
    PE_TZ1, PE_TZ2, PE_TZ3, PE_TZ4, PE_TC1, PE_TC2, PE_TC3, PE_TC4,
    // Tilting the controller (gyro controllers).
    PE_TILT_LEFT, PE_TILT_RIGHT, PE_TILT_FWD, PE_TILT_BACK,
    PE_INPUTS                               // 45
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
    /// The top active layer (0 = base) or the gyro's on/off changed. gyro: −1 not used, 0 off, 1 on. Optional.
    void (*state)(void *ctx, int layer, int gyro);
    /// A macro types text (UTF-8). Optional.
    void (*text)(void *ctx, const char *utf8);
    /// A radial menu opened, pointed at a slice, or closed: slice −1 nothing yet, −2 closed (its choice, if any, has
    /// been carried out). Menu PE_KEYBOARD_MENU with slice 1: the on-screen keyboard was asked for. Optional.
    void (*menu)(void *ctx, int menu, int slice);
    /// Gyro calibration: 0…1 while it's measuring (keep the controller still), 1 when done, −1 when it was moved
    /// and starts over. Optional.
    void (*calibration)(void *ctx, float progress);
} pe_sink;

typedef struct pe_engine pe_engine;

/// NULL when the text isn't a profile. Unknown words are skipped, so older engines read newer profiles.
pe_engine *pe_create(const char *profile_text, pe_sink sink);
void pe_destroy(pe_engine *e);
/// Applies binding-only edits in place, preserving unaffected holds. Returns false
/// for other settings or unsupported pulse/simultaneous/macro/toggle transitions;
/// equivalent text is a no-op. Caller must use safe full replacement on false.
bool pe_update_bindings(pe_engine *e, const char *profile_text);
/// Binding edits or compatible stick/gyro tuning, preserving unrelated runtime state.
bool pe_update_profile(pe_engine *e, const char *profile_text);
int pe_active_layer(const pe_engine *e);
int pe_active_gyro(const pe_engine *e);
/// Explicit Gyro off holds pause other motion sources independently of controller gyro output mode.
bool pe_motion_paused(const pe_engine *e);
/// Optional source touch gate. An explicit gyro-off hold still wins.
void pe_gyro_touch(pe_engine *e, bool required, bool touched);
/// Releases everything the engine is holding down (keys, mouse buttons, controller buttons) and centres the sticks.
void pe_release_all(pe_engine *e, double now);
/// Releases only actions owned by an additional device slot and neutralizes its axes.
void pe_release_device(pe_engine *e, int slot, double now);
/// Releases the primary controller group, preserving configured additional device slots.
void pe_release_main(pe_engine *e, double now);

void pe_button(pe_engine *e, int button, bool down, double now);     // SDL button numbers (0…20)
#define PE_ALL_INPUTS (PE_INPUTS + PE_MAX_DEVICES * PE_DEV_INPUTS)
void pe_axis(pe_engine *e, int axis, int value, double now);
/// Gyro in radians per second, SDL's axes: x pitch (up +), y yaw (left +), z roll.
void pe_gyro(pe_engine *e, float x, float y, float z, double now);
/// Timers (tap/hold, turbo, mouse sticks, flicks). Call by pe_next_deadline, or every few milliseconds.
void pe_tick(pe_engine *e, double now);
/// The next time pe_tick has something to do; 0 when nothing is pending.
double pe_next_deadline(const pe_engine *e);
/// Whether the engine wants gyro data (some binding or setting uses it).
bool pe_uses_gyro(const pe_engine *e);
enum { PE_KEYBOARD_MENU = 255, PE_RUMBLE_MENU = 254 };   // sink.menu ids: the on-screen keyboard, a rumble
/// The touchpad: finger 0 or 1 touching (or lifted), at x, y 0…1 (y down).
void pe_touch(pe_engine *e, int finger, bool down, float x, float y, double now);
bool pe_uses_touch(const pe_engine *e);
/// Native touch event visibility in the intercepted Wine SDL path only.
bool pe_touch_passthrough(const pe_engine *e);
/// The accelerometer (any unit; only its direction counts), the gyro's axes: x right, y up out of the face, z towards you.
void pe_accel(pe_engine *e, float x, float y, float z, double now);
bool pe_uses_tilt(const pe_engine *e);
/// Measures the gyro's resting drift now (2 seconds; put the controller down or hold it still).
void pe_calibrate(pe_engine *e, double now);
bool pe_calibration_is_manual(const pe_engine *e);
/* Relative pointer motion, y down. Returns true only while a pointer-picked
 * radial menu consumes it; never posts OS events. Zero motion keeps selection. */
bool pe_menu_mouse(pe_engine *e, double dx, double dy);

// MARK: Extra devices (joysticks, throttles, pedals, wheels, button boxes, a second controller)
// A profile can combine up to PE_MAX_DEVICES more devices (slots 1…4) with the controller. Their buttons, hat and
// axes are inputs like the controller's ("d1b0" button 1, "d1hu" hat up, "d1a2p"/"d1a2n" axis 3 pushed past its
// press point either way), and each axis can also move one of the controller's sticks or triggers, or the mouse.
// Buttons and axes are numbered the way SDL numbers them (sorted by HID usage), so they mean the same thing
// inside Wine and on the Mac. A device marked as a controller ("kind=gamepad") uses SDL's controller numbering;
// "join=1" makes it part of the main controller (anything it doesn't set acts as the controller's own).
enum { PE_MAX_DEVICES = 4, PE_DEV_BUTTONS = 32, PE_DEV_AXES = 8, PE_DEV_INPUTS = PE_DEV_BUTTONS + 4 + 2 * PE_DEV_AXES };
enum { PE_HAT_UP = 1, PE_HAT_RIGHT = 2, PE_HAT_DOWN = 4, PE_HAT_LEFT = 8 };
void pe_dev_button(pe_engine *e, int slot, int button, bool down, double now);
/// The hat's direction bits (PE_HAT_…), like SDL's.
void pe_dev_hat(pe_engine *e, int slot, int bits, double now);
void pe_dev_axis(pe_engine *e, int slot, int axis, int value, double now);     // −32768…32767
/// How many device slots the profile names (the highest slot number), and what each one is.
int pe_device_count(const pe_engine *e);
bool pe_device_info(const pe_engine *e, int slot, int *vendor, int *product, int *nth, bool *gamepad, bool *joined);
/// Whether the profile does something with this part of a device — then a Windows game doesn't also get it from
/// the device itself. kind 0 a button, 1 the hat, 2 an axis.
bool pe_dev_uses(const pe_engine *e, int slot, int kind, int n);

/// Input name ("a", "lb", "ltfull", "d1b3"…) ↔ number; -1 when unknown.
int pe_input_named(const char *name);
const char *pe_input_name(int input);

#ifdef __cplusplus
}
#endif
#endif
