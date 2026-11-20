// SPDX-License-Identifier: GPL-3.0-only
// ARM engine probe: what the program sees (machine, emulation) and how fast plain CPU work runs, for comparing
// an x86 engine under Rosetta with an ARM engine under FEX. Prints one line per measurement.
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static double now_ms(void) {
    static LARGE_INTEGER f; LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

static volatile unsigned long long sink;

static double integer_work(void) {
    double t = now_ms(); unsigned long long x = 88172645463325252ULL, s = 0;
    for (int i = 0; i < 200000000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; s += x & 0xff; }
    sink = s; return now_ms() - t;
}
static double float_work(void) {
    double t = now_ms(), a = 0;
    for (int i = 1; i < 50000000; i++) a += sqrt((double)i) * sin((double)i * 0.001);
    sink = (unsigned long long)a; return now_ms() - t;
}
static double memory_work(void) {
    size_t n = 64u << 20; char *a = malloc(n), *b = malloc(n);
    if (!a || !b) return -1;
    memset(a, 1, n); double t = now_ms();
    for (int i = 0; i < 20; i++) { memcpy(b, a, n); a[i] = b[n - 1 - i]; }
    sink = a[5]; free(a); free(b); return now_ms() - t;
}
static DWORD WINAPI spin(void *p) { volatile LONG *c = p; for (int i = 0; i < 2000000; i++) InterlockedIncrement(c); return 0; }
static double thread_work(void) {
    volatile LONG c = 0; HANDLE h[4]; double t = now_ms();
    for (int i = 0; i < 4; i++) h[i] = CreateThread(NULL, 0, spin, (void *)&c, 0, NULL);
    WaitForMultipleObjects(4, h, TRUE, INFINITE);
    for (int i = 0; i < 4; i++) CloseHandle(h[i]);
    return now_ms() - t;
}

int main(void) {
    SYSTEM_INFO si; GetNativeSystemInfo(&si);
    USHORT proc = 0, native = 0;
    BOOL (WINAPI *wow2)(HANDLE, USHORT *, USHORT *) = (void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process2");
    if (wow2) wow2(GetCurrentProcess(), &proc, &native);
    printf("program %s, native machine 0x%04x, process machine 0x%04x, processors %lu\n",
           sizeof(void *) == 8 ? "x86_64" : "i386", native, proc, si.dwNumberOfProcessors);
    int r[4] = {0}; 
#if defined(__GNUC__)
    __asm__ volatile ("cpuid" : "=a"(r[0]), "=b"(r[1]), "=c"(r[2]), "=d"(r[3]) : "a"(1), "c"(0));
#endif
    printf("cpuid sse4.2 %d avx %d\n", (r[2] >> 20) & 1, (r[2] >> 28) & 1);
    printf("integer %.0f ms\n", integer_work());
    printf("float %.0f ms\n", float_work());
    printf("memory %.0f ms\n", memory_work());
    printf("threads %.0f ms\n", thread_work());
    fflush(stdout);
    return 0;
}
