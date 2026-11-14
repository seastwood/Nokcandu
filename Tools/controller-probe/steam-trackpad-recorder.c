// SPDX-License-Identifier: GPL-3.0-only
// Read-only recorder for the original Steam Controller (cable 28de:1102 or receiver 28de:1142), run alongside
// Nokcandu without taking the controller over. One line per input report:
//   seconds  sequence  rightTouch  (unused)  rightPadX  rightPadY  gyroX  gyroY  gyroZ
// Pad coordinates are raw −32768…32767, y up (Nokcandu uses (x+1)/2 and (1−y)/2 of x/32767).
// Build: xcrun clang -O2 -framework IOKit -framework CoreFoundation steam-trackpad-recorder.c -o steam-trackpad-recorder
// Run:   ./steam-trackpad-recorder out.txt 60      (seconds; no device commands are sent)
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <stdio.h>
#include <mach/mach_time.h>
static FILE *out; static uint8_t buf[8][64]; static double t0;
static double now(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9; }
static void cb(void *ctx, IOReturn r, void *s, IOHIDReportType ty, uint32_t id, uint8_t *b, CFIndex n) {
    if (r || n != 64 || b[0] != 1 || b[1] != 0 || b[2] != 1 || b[3] < 44 || b[3] > 60) return;
    uint32_t flags = b[8] | b[9] << 8 | b[10] << 16;
    int16_t x = (int16_t)(b[20] | b[21] << 8), y = (int16_t)(b[22] | b[23] << 8);
    int16_t gx = (int16_t)(b[34] | b[35] << 8), gy = (int16_t)(b[36] | b[37] << 8), gz = (int16_t)(b[38] | b[39] << 8);
    uint32_t seq = b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24;
    fprintf(out, "%.4f %u %d %d %d %d %d %d %d\n", now() - t0, seq, (flags >> 20) & 1, (flags >> 4) & 1 ? 1 : 0, x, y, gx, gy, gz);
}
static void added(void *ctx, IOReturn r, void *s, IOHIDDeviceRef d) {
    static int k; IOHIDDeviceRegisterInputReportCallback(d, buf[k++ % 8], 64, cb, NULL);
    fprintf(stderr, "device added\n");
}
int main(int argc, char **argv) {
    out = fopen(argv[1], "w"); setvbuf(out, NULL, _IOLBF, 0); t0 = now();
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    int vid = 0x28de, page = 0xff00, usage = 1, pids[2] = { 0x1102, 0x1142 };
    CFMutableArrayRef arr = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < 2; i++) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid), p = CFNumberCreate(NULL, kCFNumberIntType, &pids[i]),
                    pg = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        CFDictionarySetValue(d, CFSTR(kIOHIDVendorIDKey), v); CFDictionarySetValue(d, CFSTR(kIOHIDProductIDKey), p);
        CFDictionarySetValue(d, CFSTR(kIOHIDDeviceUsagePageKey), pg); CFDictionarySetValue(d, CFSTR(kIOHIDDeviceUsageKey), u);
        CFArrayAppendValue(arr, d);
    }
    IOHIDManagerSetDeviceMatchingMultiple(m, arr);
    IOHIDManagerRegisterDeviceMatchingCallback(m, added, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    fprintf(stderr, "open %x\n", r);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, argc > 2 ? atof(argv[2]) : 90, false);
    return 0;
}
