// SPDX-License-Identifier: LGPL-2.1-or-later (also built into Nokcandu's Wine controller driver)
// Virtual controller reports (see virtualpad.h): the DualShock 4 and Switch Pro Controller as verified in Wine
// (USB report layouts, the Pro's handshake and subcommands, the DS4's feature reports), and the Xbox Wireless
// Controller's Bluetooth HID report (as Linux's hid-microsoft and xpadneo document it).
#include "virtualpad.h"
#include <string.h>

enum { B_A, B_B, B_X, B_Y, B_BACK, B_GUIDE, B_START, B_LS, B_RS, B_LB, B_RB, B_UP, B_DOWN, B_LEFT, B_RIGHT, B_MISC,
       B_P1, B_P2, B_P3, B_P4, B_TOUCHPAD };
enum { A_LX, A_LY, A_RX, A_RY, A_LT, A_RT };
#define DOWN(s, b) (((s)->buttons >> (b)) & 1u)

// MARK: Descriptors

static const uint8_t xbox_descriptor[] = {
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01,
    0x09, 0x01, 0xa1, 0x00, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x27, 0xff, 0xff, 0x00, 0x00, 0x95, 0x02, 0x75, 0x10, 0x81, 0x02, 0xc0,
    0x09, 0x01, 0xa1, 0x00, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x27, 0xff, 0xff, 0x00, 0x00, 0x95, 0x02, 0x75, 0x10, 0x81, 0x02, 0xc0,
    0x05, 0x02, 0x09, 0xc5, 0x15, 0x00, 0x26, 0xff, 0x03, 0x95, 0x01, 0x75, 0x0a, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00, 0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x02, 0x09, 0xc4, 0x15, 0x00, 0x26, 0xff, 0x03, 0x95, 0x01, 0x75, 0x0a, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00, 0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x35, 0x00, 0x46, 0x3b, 0x01, 0x66, 0x14, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
    0x75, 0x04, 0x95, 0x01, 0x15, 0x00, 0x25, 0x00, 0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x81, 0x03,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0f, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0f, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00, 0x75, 0x01, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x0c, 0x0a, 0xb2, 0x00, 0x15, 0x00, 0x25, 0x01, 0x95, 0x01, 0x75, 0x01, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00, 0x75, 0x07, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x0f, 0x09, 0x21, 0x85, 0x03, 0xa1, 0x02, 0x09, 0x97, 0x15, 0x00, 0x25, 0x01, 0x75, 0x04, 0x95, 0x01, 0x91, 0x02,
    0x15, 0x00, 0x25, 0x00, 0x75, 0x04, 0x95, 0x01, 0x91, 0x03, 0x09, 0x70, 0x15, 0x00, 0x25, 0x64, 0x75, 0x08, 0x95, 0x04, 0x91, 0x02,
    0x09, 0x50, 0x66, 0x01, 0x10, 0x55, 0x0e, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x01, 0x91, 0x02,
    0x09, 0xa7, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x01, 0x91, 0x02, 0x65, 0x00, 0x55, 0x00,
    0x09, 0x7c, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x01, 0x91, 0x02, 0xc0,
    0xc0,
};

static const uint8_t ds4_descriptor[] = {
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
    0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3b, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
    0x65, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0e, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0e, 0x81, 0x02,
    0x06, 0x00, 0xff, 0x09, 0x20, 0x75, 0x06, 0x95, 0x01, 0x15, 0x00, 0x25, 0x7f, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x33, 0x09, 0x34, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    0x06, 0x00, 0xff, 0x09, 0x21, 0x95, 0x36, 0x81, 0x02,
    0x85, 0x05, 0x09, 0x22, 0x95, 0x1f, 0x91, 0x02,
    0x85, 0x04, 0x09, 0x23, 0x95, 0x24, 0xb1, 0x02,
    0x85, 0x02, 0x09, 0x24, 0x95, 0x24, 0xb1, 0x02,
    0x85, 0x08, 0x09, 0x25, 0x95, 0x03, 0xb1, 0x02,
    0x85, 0x10, 0x09, 0x26, 0x95, 0x04, 0xb1, 0x02,
    0x85, 0x11, 0x09, 0x27, 0x95, 0x02, 0xb1, 0x02,
    0x85, 0x12, 0x06, 0x02, 0xff, 0x09, 0x21, 0x95, 0x0f, 0xb1, 0x02,
    0x85, 0x13, 0x09, 0x22, 0x95, 0x16, 0xb1, 0x02,
    0x85, 0x14, 0x06, 0x05, 0xff, 0x09, 0x20, 0x95, 0x10, 0xb1, 0x02,
    0x85, 0x15, 0x09, 0x21, 0x95, 0x2c, 0xb1, 0x02,
    0x06, 0x80, 0xff,
    0x85, 0xa3, 0x09, 0x23, 0x95, 0x30, 0xb1, 0x02,
    0xc0,
};

// The Pro's descriptor with its full-state 0x30 report described as buttons and sticks (Engine/controller-hid/pro-hid-descriptor.h).
static const uint8_t pro_descriptor[] = {
    0x05, 0x01, 0x09, 0x04, 0xa1, 0x01, 0x85, 0x30, 0x06, 0x00, 0xff, 0x09, 0x01, 0x15, 0x00, 0x26,
    0xff, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x03, 0x05, 0x09, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x19, 0x01, 0x29, 0x04, 0x95, 0x04, 0x81, 0x02, 0x95, 0x02, 0x81, 0x03, 0x19, 0x05, 0x29, 0x0c,
    0x95, 0x08, 0x81, 0x02, 0x95, 0x02, 0x81, 0x03, 0x19, 0x0d, 0x29, 0x10, 0x95, 0x04, 0x81, 0x02,
    0x95, 0x02, 0x81, 0x03, 0x19, 0x11, 0x29, 0x12, 0x95, 0x02, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30,
    0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xff, 0x0f, 0x75, 0x0c, 0x95, 0x04, 0x81,
    0x02, 0x06, 0x00, 0xff,
    0x09, 0x02, 0x75, 0x08, 0x95, 0x34, 0x81, 0x03, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x46, 0x3b,
    0x01, 0x65, 0x14, 0x55, 0x00, 0x06, 0x00, 0xff, 0x85, 0x21, 0x09, 0x01, 0x75, 0x08, 0x95, 0x3f,
    0x81, 0x03, 0x85, 0x81, 0x09, 0x02, 0x75, 0x08, 0x95, 0x3f, 0x81, 0x03, 0x85, 0x01, 0x09, 0x03,
    0x75, 0x08, 0x95, 0x3f, 0x91, 0x83, 0x85, 0x10, 0x09, 0x04, 0x75, 0x08, 0x95, 0x3f, 0x91, 0x83,
    0x85, 0x80, 0x09, 0x05, 0x75, 0x08, 0x95, 0x3f, 0x91, 0x83, 0x85, 0x82, 0x09, 0x06, 0x75, 0x08,
    0x95, 0x3f, 0x91, 0x83, 0xc0
};

void vp_init(vp_device *d, int kind, uint8_t address_salt) {
    memset(d, 0, sizeof *d);
    d->kind = kind;
    d->address_salt = address_salt;
    d->pro_full = true;
    d->next_finger = 2;
}

uint16_t vp_vendor(int kind) { return kind == VP_XBOX ? 0x045e : kind == VP_DS4 ? 0x054c : 0x057e; }
uint16_t vp_product(int kind) { return kind == VP_XBOX ? 0x0b13 : kind == VP_DS4 ? 0x05c4 : 0x2009; }
const char *vp_name(int kind) { return kind == VP_XBOX ? "Xbox Wireless Controller" : kind == VP_DS4 ? "Wireless Controller" : "Pro Controller"; }
const char *vp_manufacturer(int kind) { return kind == VP_XBOX ? "Microsoft" : kind == VP_DS4 ? "Sony Computer Entertainment" : "Nintendo Co., Ltd."; }
int vp_report_interval_ms(int kind) { return kind == VP_DS4 ? 4 : 8; }

const uint8_t *vp_descriptor(int kind, size_t *length) {
    switch (kind) {
    case VP_XBOX: *length = sizeof xbox_descriptor; return xbox_descriptor;
    case VP_DS4: *length = sizeof ds4_descriptor; return ds4_descriptor;
    default: *length = sizeof pro_descriptor; return pro_descriptor;
    }
}

static void put16(uint8_t *out, int v) {
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    out[0] = (uint8_t)(v & 0xff); out[1] = (uint8_t)((v >> 8) & 0xff);
}
static void putu16(uint8_t *out, unsigned v) { out[0] = (uint8_t)(v & 0xff); out[1] = (uint8_t)((v >> 8) & 0xff); }

// MARK: Xbox Wireless Controller (Bluetooth report 0x01)

static size_t xbox_input(const vp_state *s, uint8_t *r) {
    memset(r, 0, 17);
    r[0] = 0x01;
    // Sticks 0…65535 with y down (like the pad engine), triggers 0…1023.
    for (int i = 0; i < 4; i++) putu16(r + 1 + i * 2, (unsigned)(s->axes[i] + 32768));
    putu16(r + 9, (unsigned)(s->axes[A_LT] > 0 ? s->axes[A_LT] * 1023 / 32767 : 0));
    putu16(r + 11, (unsigned)(s->axes[A_RT] > 0 ? s->axes[A_RT] * 1023 / 32767 : 0));
    bool up = DOWN(s, B_UP), down = DOWN(s, B_DOWN), left = DOWN(s, B_LEFT), right = DOWN(s, B_RIGHT);
    uint8_t hat = 0;
    if (up && right) hat = 2; else if (right && down) hat = 4; else if (down && left) hat = 6; else if (left && up) hat = 8;
    else if (up) hat = 1; else if (right) hat = 3; else if (down) hat = 5; else if (left) hat = 7;
    r[13] = hat;
    // Buttons 1…15: A B (gap) X Y (gap) LB RB (gap gap) View Menu Xbox LS RS.
    uint16_t b = (uint16_t)(DOWN(s, B_A) | DOWN(s, B_B) << 1 | DOWN(s, B_X) << 3 | DOWN(s, B_Y) << 4 | DOWN(s, B_LB) << 6 | DOWN(s, B_RB) << 7
                            | DOWN(s, B_BACK) << 10 | DOWN(s, B_START) << 11 | DOWN(s, B_GUIDE) << 12 | DOWN(s, B_LS) << 13 | DOWN(s, B_RS) << 14);
    putu16(r + 14, b);
    r[16] = (uint8_t)DOWN(s, B_MISC);          // Share
    return 17;
}

// MARK: DualShock 4 (USB report 0x01)

static uint8_t ds4_stick(int16_t v) { return (uint8_t)((v + 32768) >> 8); }

static size_t ds4_input(vp_device *d, const vp_state *s, uint8_t *r) {
    memset(r, 0, 64);
    uint8_t l2 = (uint8_t)(s->axes[A_LT] > 0 ? s->axes[A_LT] >> 7 : 0), r2 = (uint8_t)(s->axes[A_RT] > 0 ? s->axes[A_RT] >> 7 : 0);
    bool up = DOWN(s, B_UP), down = DOWN(s, B_DOWN), left = DOWN(s, B_LEFT), right = DOWN(s, B_RIGHT);
    uint8_t hat = 8;
    if (up && right) hat = 1; else if (right && down) hat = 3; else if (down && left) hat = 5; else if (left && up) hat = 7;
    else if (up) hat = 0; else if (right) hat = 2; else if (down) hat = 4; else if (left) hat = 6;
    r[0] = 0x01;
    r[1] = ds4_stick(s->axes[A_LX]); r[2] = ds4_stick(s->axes[A_LY]); r[3] = ds4_stick(s->axes[A_RX]); r[4] = ds4_stick(s->axes[A_RY]);
    r[5] = (uint8_t)(hat | DOWN(s, B_X) << 4 | DOWN(s, B_A) << 5 | DOWN(s, B_B) << 6 | DOWN(s, B_Y) << 7);
    r[6] = (uint8_t)(DOWN(s, B_LB) | DOWN(s, B_RB) << 1 | (l2 > 0) << 2 | (r2 > 0) << 3 | DOWN(s, B_BACK) << 4 | DOWN(s, B_START) << 5
                     | DOWN(s, B_LS) << 6 | DOWN(s, B_RS) << 7);
    r[7] = (uint8_t)(DOWN(s, B_GUIDE) | DOWN(s, B_TOUCHPAD) << 1 | (d->counter++ & 0x3f) << 2);
    r[8] = l2; r[9] = r2;
    d->timestamp = (uint16_t)(d->timestamp + 188);
    putu16(r + 10, d->timestamp);
    const float deg = 57.29578f, g = 9.80665f;
    for (int i = 0; i < 3; i++) put16(r + 13 + i * 2, (int)(s->gyro[i] * deg * 15.17f));
    for (int i = 0; i < 3; i++) put16(r + 19 + i * 2, (int)(s->accel[i] / g * 8192));
    r[30] = 0x1b;
    r[33] = 1;
    r[34] = d->touch_counter;
    for (int i = 0; i < 2; i++) {
        uint8_t *f = r + 35 + i * 4;
        int x = (int)(s->finger[i].x * 1919), y = (int)(s->finger[i].y * 941);
        f[0] = (uint8_t)((s->finger[i].id & 0x7f) | (s->finger[i].down ? 0 : 0x80));
        f[1] = (uint8_t)(x & 0xff); f[2] = (uint8_t)(((x >> 8) & 0x0f) | ((y & 0x0f) << 4)); f[3] = (uint8_t)((y >> 4) & 0xff);
    }
    return 64;
}

// MARK: Switch Pro Controller (USB)

enum { PRO_CENTER = 2048, PRO_RANGE = 1792 };

static void pro_pack(uint8_t *out, int x, int y) {
    out[0] = (uint8_t)(x & 0xff); out[1] = (uint8_t)(((x >> 8) & 0x0f) | ((y & 0x0f) << 4)); out[2] = (uint8_t)((y >> 4) & 0xff);
}
static int pro_axis(int16_t v, bool invert) {
    int a = invert ? -(int)v - 1 : v, r = PRO_CENTER + a * PRO_RANGE / 32768;
    return r < 0 ? 0 : r > 4095 ? 4095 : r;
}

static void pro_state(vp_device *d, const vp_state *s, uint8_t *r) {
    r[1] = d->timer++;
    r[2] = 0x91;
    r[3] = (uint8_t)(DOWN(s, B_X) | DOWN(s, B_Y) << 1 | DOWN(s, B_A) << 2 | DOWN(s, B_B) << 3 | DOWN(s, B_RB) << 6 | (s->axes[A_RT] > 16384) << 7);
    r[4] = (uint8_t)(DOWN(s, B_BACK) | DOWN(s, B_START) << 1 | DOWN(s, B_RS) << 2 | DOWN(s, B_LS) << 3 | DOWN(s, B_GUIDE) << 4 | DOWN(s, B_MISC) << 5);
    r[5] = (uint8_t)(DOWN(s, B_DOWN) | DOWN(s, B_UP) << 1 | DOWN(s, B_RIGHT) << 2 | DOWN(s, B_LEFT) << 3 | DOWN(s, B_LB) << 6 | (s->axes[A_LT] > 16384) << 7);
    pro_pack(r + 6, pro_axis(s->axes[A_LX], false), pro_axis(s->axes[A_LY], true));
    pro_pack(r + 9, pro_axis(s->axes[A_RX], false), pro_axis(s->axes[A_RY], true));
    r[12] = 0x80;
}

static void pro_imu(const vp_state *s, uint8_t *r) {
    const float g = 9.80665f, deg = 57.29578f;
    int ax = (int)(-s->accel[2] / g * 4096), ay = (int)(-s->accel[0] / g * 4096), az = (int)(s->accel[1] / g * 4096);
    int gx = (int)(-s->gyro[2] * deg * 14.2853f), gy = (int)(-s->gyro[0] * deg * 14.2853f), gz = (int)(s->gyro[1] * deg * 14.2853f);
    for (int i = 0; i < 3; i++) {
        uint8_t *x = r + 13 + i * 12;
        put16(x, ax); put16(x + 2, ay); put16(x + 4, az); put16(x + 6, gx); put16(x + 8, gy); put16(x + 10, gz);
    }
}

static uint8_t pro_flash(unsigned address) {
    static const uint8_t colours[13] = {0x32, 0x32, 0x32, 0xe6, 0xe6, 0xe6, 0x46, 0x46, 0x46, 0x46, 0x46, 0x46, 0xff};
    static const uint8_t params[18] = {0x0f, 0x30, 0x61, 0x96, 0x30, 0xf3, 0xd4, 0x14, 0x54, 0x41, 0x15, 0x54, 0xc7, 0x79, 0x9c, 0x33, 0x36, 0x63};
    if (address >= 0x6020 && address < 0x6038) {
        unsigned i = address - 0x6020;
        if (i >= 6 && i < 12) return (i & 1) ? 0x40 : 0x00;
        if (i >= 18) return (i & 1) ? 0x34 : 0x3b;
        return 0;
    }
    if (address >= 0x603d && address < 0x604f) {
        uint8_t range[3], centre[3], cal[18];
        pro_pack(range, PRO_RANGE, PRO_RANGE); pro_pack(centre, PRO_CENTER, PRO_CENTER);
        memcpy(cal, range, 3); memcpy(cal + 3, centre, 3); memcpy(cal + 6, range, 3);
        memcpy(cal + 9, centre, 3); memcpy(cal + 12, range, 3); memcpy(cal + 15, range, 3);
        return cal[address - 0x603d];
    }
    if (address >= 0x6050 && address < 0x605d) return colours[address - 0x6050];
    if (address >= 0x6086 && address < 0x6098) return params[address - 0x6086];
    if (address >= 0x6098 && address < 0x60aa) return params[address - 0x6098];
    if (address == 0x6012) return 0x03;
    if (address == 0x601b) return 0x01;
    return 0xff;
}

static void pro_reply(vp_device *d, const vp_state *s, uint8_t ack, uint8_t sub, const uint8_t *data, size_t n,
                      void (*reply)(void *, const uint8_t *, size_t), void *ctx) {
    uint8_t r[64] = {0x21};
    pro_state(d, s, r);
    r[13] = ack; r[14] = sub;
    if (data && n) memcpy(r + 15, data, n > 49 ? 49 : n);
    reply(ctx, r, 64);
}

static void pro_rumble(vp_device *d, const uint8_t *x) {
    int hi = (x[1] >> 1) & 0x7f, lo = (x[3] - 0x40) & 0x7f, hi2 = (x[5] >> 1) & 0x7f, lo2 = (x[7] - 0x40) & 0x7f;
    int strong = lo > lo2 ? lo : lo2, weak = hi > hi2 ? hi : hi2;
    uint16_t a = (uint16_t)(strong * 65535 / 0x7f), b = (uint16_t)(weak * 65535 / 0x7f);
    if (a != d->rumble_strong || b != d->rumble_weak) { d->rumble_strong = a; d->rumble_weak = b; d->rumble_changed = true; }
}

static void pro_output(vp_device *d, const vp_state *s, const uint8_t *x, size_t n, void (*reply)(void *, const uint8_t *, size_t), void *ctx) {
    if (n >= 2 && x[0] == 0x80) {
        uint8_t r[64] = {0x81, x[1]};
        if (x[1] == 0x01) { uint8_t mac[8] = {0x00, 0x03, 0x6e, 0xd4, 0x1e, 0x8a, 0xbb, 0x7c}; mac[7] ^= d->address_salt; memcpy(r + 2, mac, 8); }
        if (x[1] <= 0x03) reply(ctx, r, 64);
        if (x[1] == 0x04) d->pro_full = true;
        return;
    }
    if (n >= 10 && (x[0] == 0x01 || x[0] == 0x10)) pro_rumble(d, x + 2);
    if (n < 11 || x[0] != 0x01) return;
    uint8_t sub = x[10];
    const uint8_t *a = x + 11; size_t len = n - 11;
    switch (sub) {
    case 0x02: {
        uint8_t info[12] = {0x03, 0x48, 0x03, 0x02, 0x7c, 0xbb, 0x8a, 0x1e, 0xd4, 0x6e, 0x01, 0x02};
        info[4] ^= d->address_salt;
        pro_reply(d, s, 0x82, sub, info, sizeof info, reply, ctx);
        break;
    }
    case 0x10: {
        uint8_t out[5 + 0x1d];
        unsigned address = len >= 4 ? (unsigned)(a[0] | a[1] << 8 | a[2] << 16 | (unsigned)a[3] << 24) : 0;
        unsigned size = len >= 5 ? a[4] : 0;
        if (size > 0x1d) size = 0x1d;
        memset(out, 0, sizeof out);
        memcpy(out, a, len >= 5 ? 5 : len);
        for (unsigned i = 0; i < size; i++) out[5 + i] = pro_flash(address + i);
        pro_reply(d, s, 0x90, sub, out, 5 + size, reply, ctx);
        break;
    }
    case 0x03: d->pro_full = len >= 1 && a[0] == 0x30; pro_reply(d, s, 0x80, sub, NULL, 0, reply, ctx); break;
    case 0x40: d->pro_imu = len >= 1 && a[0] != 0; pro_reply(d, s, 0x80, sub, NULL, 0, reply, ctx); break;
    case 0x01: { uint8_t v = 0x03; pro_reply(d, s, 0x81, sub, &v, 1, reply, ctx); break; }
    case 0x04: { uint8_t z[16] = {0}; pro_reply(d, s, 0x83, sub, z, 16, reply, ctx); break; }
    case 0x21: { uint8_t m[8] = {0x01, 0x00, 0xff, 0x00, 0x08, 0x00, 0x1b, 0x01}; pro_reply(d, s, 0xa0, sub, m, 8, reply, ctx); break; }
    default: pro_reply(d, s, 0x80, sub, NULL, 0, reply, ctx); break;
    }
}

// MARK: Shared entry points

size_t vp_input_report(vp_device *d, const vp_state *s, uint8_t *out, size_t capacity) {
    if (capacity < 64) return 0;
    switch (d->kind) {
    case VP_XBOX: return xbox_input(s, out);
    case VP_DS4: if (s->finger[0].down || s->finger[1].down) d->touch_counter++; return ds4_input(d, s, out);
    case VP_SWITCH_PRO:
        if (!d->pro_full) return 0;
        memset(out, 0, 64);
        out[0] = 0x30;
        pro_state(d, s, out);
        if (d->pro_imu) pro_imu(s, out);
        return 64;
    }
    return 0;
}

void vp_output(vp_device *d, const vp_state *s, const uint8_t *x, size_t n, void (*reply)(void *, const uint8_t *, size_t), void *ctx) {
    if (!x || !n) return;
    if (d->kind == VP_SWITCH_PRO) { pro_output(d, s, x, n, reply, ctx); return; }
    if (d->kind == VP_DS4 && n >= 9 && x[0] == 0x05) {
        if (x[1] & 0x01) {
            uint16_t a = (uint16_t)(x[5] * 257), b = (uint16_t)(x[4] * 257);
            if (a != d->rumble_strong || b != d->rumble_weak) { d->rumble_strong = a; d->rumble_weak = b; d->rumble_changed = true; }
        }
        if (x[1] & 0x02) { d->light[0] = x[6]; d->light[1] = x[7]; d->light[2] = x[8]; d->light_changed = true; }
        return;
    }
    if (d->kind == VP_XBOX && n >= 9 && x[0] == 0x03) {
        // Enable bits, then four magnitudes 0…100: left trigger, right trigger, strong (left), weak (right).
        uint16_t a = (uint16_t)(x[4] * 65535 / 100), b = (uint16_t)(x[5] * 65535 / 100);
        if (a != d->rumble_strong || b != d->rumble_weak) { d->rumble_strong = a; d->rumble_weak = b; d->rumble_changed = true; }
    }
}

size_t vp_feature(vp_device *d, uint8_t id, uint8_t *out, size_t capacity) {
    uint8_t r[64] = {0};
    size_t size = 0;
    if (d->kind != VP_DS4) return 0;
    switch (id) {
    case 0x02: {
        static const short cal[17] = {0, 0, 0, 8192, -8192, 8192, -8192, 8192, -8192, 540, 540, 8192, -8192, 8192, -8192, 8192, -8192};
        r[0] = 0x02;
        for (int i = 0; i < 17; i++) { r[1 + i * 2] = (uint8_t)(cal[i] & 0xff); r[2 + i * 2] = (uint8_t)((cal[i] >> 8) & 0xff); }
        size = 37;
        break;
    }
    case 0x12: {
        static const uint8_t mac[15] = {0xd4, 0x1e, 0x8a, 0xbb, 0x7c, 0x6e, 0x08, 0x25};
        r[0] = 0x12; memcpy(r + 1, mac, sizeof mac); r[1] ^= d->address_salt;
        size = 16;
        break;
    }
    case 0xa3:
        r[0] = 0xa3; memcpy(r + 1, "Sep 21 2018", 11); memcpy(r + 17, "04:50:51", 8);
        r[33] = 0x01; r[36] = 0x01; r[41] = 0xb4; r[42] = 0x01;
        size = 49;
        break;
    default:
        return 0;
    }
    if (size > capacity) size = capacity;
    memcpy(out, r, size);
    return size;
}
