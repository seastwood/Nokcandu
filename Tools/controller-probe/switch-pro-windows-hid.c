/* Windows-side check of Nokcandu's imitated Switch Pro Controller and DualShock 4 (run inside a Wine environment):
 * lists HID game controllers, opens 057e:2009, sends the USB status/handshake commands and a device-info
 * subcommand the way SDL does, and prints the replies and a few full-state (0x30) reports. Only Pro protocol
 * requests that a real Pro answers harmlessly; no pairing, flash writes or firmware commands. */
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int readReport(HANDLE h, unsigned char *buf, DWORD len, DWORD ms) {
    OVERLAPPED ov = {0}; ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    DWORD got = 0;
    if (!ReadFile(h, buf, len, &got, &ov)) {
        if (GetLastError() != ERROR_IO_PENDING || WaitForSingleObject(ov.hEvent, ms) != WAIT_OBJECT_0) { CancelIo(h); CloseHandle(ov.hEvent); return 0; }
        GetOverlappedResult(h, &ov, &got, FALSE);
    }
    CloseHandle(ov.hEvent);
    return (int)got;
}
static void writeReport(HANDLE h, unsigned char *buf, DWORD len) {
    OVERLAPPED ov = {0}; ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL); DWORD n = 0;
    if (!WriteFile(h, buf, len, &n, &ov) && GetLastError() == ERROR_IO_PENDING) WaitForSingleObject(ov.hEvent, 500);
    CloseHandle(ov.hEvent);
}
/* Waits for a report with this id (and second byte, or subcommand byte for 0x21). */
static int waitFor(HANDLE h, unsigned char id, int match, unsigned char *out, DWORD len) {
    for (int i = 0; i < 40; i++) {
        int n = readReport(h, out, len, 100);
        if (n <= 0) continue;
        if (out[0] != id) continue;
        if (match < 0 || (id == 0x21 ? out[14] : out[1]) == match) return n;
    }
    return 0;
}
static void hex(const char *what, unsigned char *b, int n) { printf("%s:", what); for (int i = 0; i < n && i < 24; i++) printf(" %02x", b[i]); printf("\n"); }

static int scan(void);
int main(void) {
    /* Wine creates its controllers shortly after it starts: look again for up to 10 seconds. */
    for (int tries = 0; tries < 10; tries++) { if (scan()) return 0; Sleep(1000); }
    printf("no game controllers found\n");
    return 1;
}
static int scan(void) {
    GUID guid; HidD_GetHidGuid(&guid);
    int controllers = 0;
    HDEVINFO list = SetupDiGetClassDevsA(&guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (list == INVALID_HANDLE_VALUE) return 2;
    int pros = 0;
    for (DWORD i = 0;; ++i) {
        SP_DEVICE_INTERFACE_DATA item = {0}; item.cbSize = sizeof(item);
        if (!SetupDiEnumDeviceInterfaces(list, NULL, &guid, i, &item)) break;
        DWORD n = 0; SetupDiGetDeviceInterfaceDetailA(list, &item, NULL, 0, &n, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A detail = malloc(n); detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailA(list, &item, detail, n, NULL, NULL)) { free(detail); continue; }
        HANDLE h = CreateFileA(detail->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
        if (h == INVALID_HANDLE_VALUE) { free(detail); continue; }
        HIDD_ATTRIBUTES a = {0}; a.Size = sizeof(a); HidD_GetAttributes(h, &a);
        PHIDP_PREPARSED_DATA pp = NULL; HIDP_CAPS caps = {0};
        if (HidD_GetPreparsedData(h, &pp)) { HidP_GetCaps(pp, &caps); HidD_FreePreparsedData(pp); }
        WCHAR name[128] = {0}; HidD_GetProductString(h, name, sizeof(name));
        if (caps.UsagePage == 1 && (caps.Usage == 4 || caps.Usage == 5)) ++controllers;
        if (caps.UsagePage == 1 && (caps.Usage == 4 || caps.Usage == 5))
            printf("controller %04x:%04x \"%ls\" usage %x:%x input %u output %u\n", a.VendorID, a.ProductID, name, caps.UsagePage, caps.Usage, caps.InputReportByteLength, caps.OutputReportByteLength);
        if (a.VendorID == 0x054c && a.ProductID == 0x05c4) {
            /* DualShock 4: the feature reports DS4-aware software reads, then input reports. */
            unsigned char f[64] = {0x02};
            BOOL ok = HidD_GetFeature(h, f, 37); printf("ds4 calibration: %s", ok ? "yes" : "no"); if (ok) hex("", f, 12); else printf("\n");
            memset(f, 0, sizeof f); f[0] = 0x12; ok = HidD_GetFeature(h, f, 16); printf("ds4 address: %s", ok ? "yes" : "no"); if (ok) hex("", f, 8); else printf("\n");
            unsigned char r[64]; int n0 = 0; DWORD start = GetTickCount();
            for (int k = 0; k < 120; k++) { int m = readReport(h, r, sizeof r, 50); if (m && r[0] == 0x01) { n0++; if (n0 == 1) hex("ds4 input report", r, m); } }
            printf("ds4 input reports in %lu ms: %d\n", GetTickCount() - start, n0);
            CloseHandle(h); free(detail); continue;
        }
        if (a.VendorID != 0x057e || a.ProductID != 0x2009) { CloseHandle(h); free(detail); continue; }
        ++pros;
        unsigned char r[64];
        unsigned char c[64] = {0x80, 0x01};
        writeReport(h, c, caps.OutputReportByteLength ? caps.OutputReportByteLength : 64);
        int got = waitFor(h, 0x81, 0x01, r, sizeof r); if (got) hex("status reply", r, got); else printf("status reply: none\n");
        c[1] = 0x02; writeReport(h, c, caps.OutputReportByteLength ? caps.OutputReportByteLength : 64);
        got = waitFor(h, 0x81, 0x02, r, sizeof r); printf("handshake reply: %s\n", got ? "yes" : "none");
        unsigned char s[64] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x02};
        writeReport(h, s, caps.OutputReportByteLength ? caps.OutputReportByteLength : 64);
        got = waitFor(h, 0x21, 0x02, r, sizeof r); if (got) hex("device info reply", r, got); else printf("device info reply: none\n");
        int full = 0; DWORD start = GetTickCount();
        for (int k = 0; k < 60; k++) { int m = readReport(h, r, sizeof r, 50); if (m && r[0] == 0x30) { full++; if (full == 1) hex("full report", r, m); } }
        printf("full reports in %lu ms: %d\n", GetTickCount() - start, full);
        CloseHandle(h); free(detail);
    }
    if (controllers) printf("Switch Pro controllers: %d\n", pros);
    return controllers;
}
