// SPDX-License-Identifier: LGPL-2.1-or-later (also built into Nokcandu's Wine controller driver)
// Virtual controllers: the reports and replies of an Xbox Wireless Controller, a DualShock 4 and a Switch Pro
// Controller, built from a mapped controller's state. Plain C with no system dependencies, for a platform's
// virtual HID device: Nokcandu's Wine controller driver (Engine/controller-hid/controller-emulation.h builds this
// file in) and, on the Mac, CoreHID's HIDVirtualDevice. One copy of the protocol for both.
#ifndef NOKCANDU_VIRTUALPAD_H
#define NOKCANDU_VIRTUALPAD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { VP_XBOX = 1, VP_DS4 = 2, VP_SWITCH_PRO = 3 };

/// A controller's state in the pad engine's terms: buttons are SDL button numbers (PE_A… = bit 0…), sticks
/// −32768…32767 with y down, triggers 0…32767, gyro in rad/s and accelerometer in m/s² (SDL's axes),
/// touchpad fingers 0…1 (DualShock 4).
typedef struct {
    uint32_t buttons;
    int16_t axes[6];
    float gyro[3], accel[3];
    struct { bool down; uint8_t id; float x, y; } finger[2];
} vp_state;

typedef struct {
    int kind;
    uint8_t address_salt;           // makes each virtual controller's address its own
    uint8_t timer, counter, touch_counter, next_finger;
    uint16_t timestamp;
    bool pro_full, pro_imu;
    /// Rumble the game asked for, 0…65535 (strong, weak); set by vp_output.
    uint16_t rumble_strong, rumble_weak;
    bool rumble_changed;
    /// DualShock 4 light bar the game set.
    uint8_t light[3];
    bool light_changed;
} vp_device;

void vp_init(vp_device *d, int kind, uint8_t address_salt);
uint16_t vp_vendor(int kind);
uint16_t vp_product(int kind);
const char *vp_name(int kind);
const char *vp_manufacturer(int kind);
const uint8_t *vp_descriptor(int kind, size_t *length);
/// How often a real one reports, in milliseconds.
int vp_report_interval_ms(int kind);

/// The periodic input report (with its report ID first). Returns its length, 0 when nothing should be sent yet.
size_t vp_input_report(vp_device *d, const vp_state *s, uint8_t *out, size_t capacity);

/// An output report from the game (report ID first). Replies the controller would send go through `reply`
/// (Switch Pro handshake and subcommand answers). Rumble and light requests are stored in the device.
void vp_output(vp_device *d, const vp_state *s, const uint8_t *data, size_t length,
               void (*reply)(void *ctx, const uint8_t *report, size_t length), void *ctx);

/// A feature report the game reads. Returns its length (report ID first), or 0 when the controller has none.
size_t vp_feature(vp_device *d, uint8_t report_id, uint8_t *out, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
