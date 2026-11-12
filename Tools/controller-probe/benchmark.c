// Offline shared-engine timing. Counting sinks never inject OS or device events.
#include "padengine.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static unsigned long emissions;
static void mouse(void *ctx, int dx, int dy) { (void)ctx; (void)dx; (void)dy; emissions++; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int compare(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static void report(const char *name, double *samples, int count) {
    double sum = 0; for (int i = 0; i < count; i++) sum += samples[i];
    qsort(samples, count, sizeof *samples, compare);
    printf("%s: n=%d mean=%.3f us p95=%.3f us max=%.3f us\n", name, count, sum * 1e6 / count, samples[(count * 95 / 100)] * 1e6, samples[count - 1] * 1e6);
}
int main(void) {
    const char *text[] = {
        "nokpad 1\nstick 1 mode=mouse dz=0 outer=1 sens=100 power=1\ngyro out=mouse min=8 max=8 smooth=0 tight=0 cal=off\nbind 0 a press=key:12\nbind 0 b press=key:13",
        "nokpad 1\nstick 1 mode=mouse dz=0 outer=1 sens=100 power=1\ngyro out=mouse min=8 max=8 smooth=0 tight=0 cal=off\nbind 0 a press=key:12\nbind 0 b press=key:14"
    };
    pe_sink sink = {0}; sink.mouse_move = mouse;
    pe_engine *e = pe_create(text[0], sink); if (!e) return 1;
    enum { INPUTS = 100000, EDITS = 1000 };
    double *samples = calloc(INPUTS, sizeof *samples); if (!samples) { pe_destroy(e); return 1; }
    pe_axis(e, PE_AXIS_RX, 24000, 1);
    for (int i = 0; i < INPUTS; i++) {
        double t = 1.004 + i * .004, start = now();
        pe_gyro(e, 0, -1, 0, t); pe_tick(e, t);
        samples[i] = now() - start;
    }
    report("gyro + tick, simulated 250 Hz", samples, INPUTS);
    for (int i = 0; i < EDITS; i++) {
        double start = now();
        if (!pe_update_profile(e, text[(i + 1) % 2])) { free(samples); pe_destroy(e); return 2; }
        samples[i] = now() - start;
    }
    report("compatible binding update", samples, EDITS);
    for (int i = 0; i < EDITS; i++) {
        double start = now();
        pe_destroy(e); e = pe_create(text[i % 2], sink);
        if (!e) { free(samples); return 1; }
        samples[i] = now() - start;
    }
    report("full engine destroy + create comparison", samples, EDITS);
    pe_destroy(e); free(samples);
    printf("counting-sink emissions=%lu; no OS injection, I/O, UI or real-time waiting\n", emissions);
    puts("CPU-only microbenchmark, not physical input latency, callback cadence or game acceptance.");
    return 0;
}
