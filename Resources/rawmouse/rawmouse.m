// Nokcandu raw mouse for aiming.
//
// Wine's Mac driver (winemac) never reads the mouse itself: it turns macOS *pointer* positions into
// game input. Those arrive about once per screen refresh, carry macOS pointer acceleration, are
// rounded to whole points, and after every SetCursorPos re-center winemac drops moves until a newer
// one arrives. Shooters that re-center each frame (Source games) end up with ~30 updates a second.
//
// While a game hides the Windows cursor (mouse-look) and its window is active, this library freezes
// the macOS pointer and feeds the game the mouse's own movement from Apple's GameController
// framework (GCMouse: hundreds of updates a second, no acceleration) as winemac relative-move
// events. Menus with a visible cursor, other apps, and Cmd-Tab use the normal path.
//
// Safety: winemac's event layout isn't public for this build, so nothing is changed until the
// library has *checked* it against real events winemac posts (type, reference count, window,
// coordinates). Anything unexpected leaves the library inert.
//
// Environment: NOKCANDU_RAW_MOUSE_SCALE (default 1), NOKCANDU_RAW_MOUSE_DEBUG=1 (log to stderr).
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <OpenGL/OpenGL.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <libgen.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Layout of winemac's event header and mouse-move payload (Wine's macdrv_cocoa.h), verified at runtime.
enum { kRefs = 0x0, kDeliver = 0x4, kType = 0x8, kWindow = 0x10, kX = 0x18, kY = 0x1c, kDrag = 0x20, kTime = 0x28 };
enum { kEventAllocSize = 256 };
// Mouse button events (the type just before relative moves): button, pressed, then the pointer position.
enum { kButton = 0x18, kPressed = 0x1c, kButtonX = 0x20, kButtonY = 0x24 };

// Where the *game's* cursor is while aiming (Windows coordinates). Games that draw their own cursor in
// menus (Battlefield 1942…) move it with our relative input, but Wine sends clicks at the frozen Mac
// pointer — so clicks are rewritten to this position. Updated from our moves and the game's own warps.
static os_unfair_lock vcur_lock = OS_UNFAIR_LOCK_INIT;
static double vcur_x, vcur_y;
static CGRect vcur_bounds;               // the game window, Windows coordinates (clamp)
static BOOL game_cursor;                 // opt-in (NOKCANDU_RAW_MOUSE_GAME_CURSOR): track the game's own cursor + move clicks there
static int button_layout = 0;            // 0 = not checked yet, 1 = verified, -1 = unknown layout (leave clicks alone)

static void vcur_set(double x, double y) {
    os_unfair_lock_lock(&vcur_lock);
    vcur_x = fmin(fmax(x, CGRectGetMinX(vcur_bounds)), CGRectGetMaxX(vcur_bounds) - 1);
    vcur_y = fmin(fmax(y, CGRectGetMinY(vcur_bounds)), CGRectGetMaxY(vcur_bounds) - 1);
    os_unfair_lock_unlock(&vcur_lock);
}

static IMP orig_handleMouseMove, orig_setCursorPosition, orig_postEvent;
static ptrdiff_t hidden_ivar = -1;
static double scale = 1.0, rest_x, rest_y;
static int relative_type = -1;           // learned from winemac's own absolute-move events
static BOOL watching_post, debug_on, installed;
static CGPoint watched_location;
static unsigned long moves_sent;

// Mouse deltas are handled on their own high-priority queue, not Wine's main thread, so they keep flowing
// when the main thread is busy (presenting frames, compiling shaders). The main thread decides *whether*
// we're aiming and publishes the target window + event queue here.
static dispatch_queue_t raw_q;
static os_unfair_lock target_lock = OS_UNFAIR_LOCK_INIT;
static void *target_window, *target_queue, *target_ctl;   // retained while armed
static _Atomic bool armed;
// Smooth movement (NOKCANDU_RAW_MOUSE_SMOOTH=1): low-rate mice (125 Hz) put 2 updates into some frames and
// 3 into others, so the view turns unevenly. Each update is spread evenly over the time until the next one
// (at most one report interval of delay). raw_q only.
static bool smooth_on;
static _Atomic bool raw_enabled;  // Raw mouse capture is on (read live from the settings file next to this library)
static double pend_x, pend_y, pend_ms, interval_ms = 8;
static uint64_t last_report;
static dispatch_source_t smooth_timer;
static bool smooth_running;
// Debug statistics (raw_q only).
static uint64_t stat_last, stat_max_gap, stat_count;
static mach_timebase_info_data_t timebase;

static void note(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void note(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "nokcandu-rawmouse: %s\n", s.UTF8String);
}
#define DEBUG(...) do { if (debug_on) note(__VA_ARGS__); } while (0)

static id controller(void) {
    Class c = objc_getClass("WineApplicationController");
    return c ? ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedController")) : nil;
}

static BOOL aiming;
static _Atomic double last_game_warp;   // when the game last moved the cursor itself (uptime, seconds)
static _Atomic int warps_while_aiming;  // the game's own cursor moves during this capture (for the log)
static double aim_started;
// Frame-synchronised delivery: while capturing, movement is handed to Wine once per frame (when the game asks
// Metal for its next frame) instead of report by report, so every frame turns by exactly one frame's worth.
// Without it Wine hands the game the movement in uneven clumps (one frame double, the next almost none).
static _Atomic uint64_t last_frame_tick;      // mach time of the last frame
static double fs_x, fs_y;                      // movement collected since the last frame (raw_q)
static bool frame_sync_off;                    // NOKCANDU_RAW_MOUSE_FRAME_SYNC=0
static uint64_t fs_frames, fs_frames_with_move;
static IMP orig_nextDrawable;
static os_unfair_lock qt_lock = OS_UNFAIR_LOCK_INIT;
static struct { void *ev; uint64_t t; } qt_ring[512];
static unsigned qt_next;
static uint64_t qt_count, qt_sum, qt_max, qt_over4, qt_over8, qt_over16;
static IMP orig_getEvent;
static _Atomic bool hid_active;
// Input timing while capturing (raw_q): how steadily mouse reports arrive, and from which mouse.
static uint64_t in_last, in_count, in_gaps4, in_max_gap;            // mach time units
static struct { IOHIDDeviceRef dev; uint64_t n; char name[64]; } in_dev[4];

static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

// Is the game confining the cursor to a small area (mouse-look), not just to its window?
static bool clip_is_small(id ctl, NSWindow *w) {
    @try {
        id h = [ctl valueForKey:@"clipCursorHandler"];
        if (!h || ![[h valueForKey:@"clippingCursor"] boolValue]) return false;
        CGRect r = [[h valueForKey:@"cursorClipRect"] rectValue];
        return r.size.width < NSWidth(w.frame) / 2 || r.size.height < NSHeight(w.frame) / 2;
    } @catch (__unused NSException *e) { return false; }
}

// The game window while the game captures the mouse (mouse-look): our app is active, a mouse is connected,
// the layout check has passed, the Windows cursor is hidden — and the game is really capturing it: it keeps
// re-centring the cursor or confines it to a small area. A hidden cursor alone isn't enough: games that draw
// their own cursor (Diablo, while dragging an item; Battlefield 1942's menus) hide it too, and must keep
// the normal pointer. Once capturing, it lasts until the cursor is shown again.
static NSWindow *aim_window(id ctl) {
    if (!atomic_load(&raw_enabled) || relative_type < 0 || !ctl || !NSApp.isActive || GCMouse.mice.count == 0 || hidden_ivar < 0) return nil;
    BOOL hidden = *(BOOL *)((char *)(__bridge void *)ctl + hidden_ivar);
    if (!hidden) return nil;
    NSWindow *w = NSApp.keyWindow;
    if (![w isKindOfClass:objc_getClass("WineWindow")]) return nil;
    if (aiming) return w;
    bool recentering = uptime() - atomic_load(&last_game_warp) < 0.5;
    return recentering || clip_is_small(ctl, w) ? w : nil;
}

static NSWindow *update_aiming(id ctl) {
    NSWindow *w = aim_window(ctl);
    BOOL now = w != nil;
    if (now != aiming) {
        aiming = now;
        if (aiming) {
            // The game's cursor starts where the Mac pointer is now (Wine last saw it there); then park
            // the frozen pointer in the middle of the game.
            NSRect f = w.frame;
            CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
            CGEventRef e = CGEventCreate(NULL);
            CGPoint p = e ? CGEventGetLocation(e) : CGPointMake(NSMidX(f), top - NSMidY(f));
            if (e) CFRelease(e);
            if (game_cursor) {
            os_unfair_lock_lock(&vcur_lock);
            vcur_bounds = CGRectMake(NSMinX(f), top - NSMaxY(f), NSWidth(f), NSHeight(f));
            os_unfair_lock_unlock(&vcur_lock);
            vcur_set(p.x, p.y);
            }
            CGWarpMouseCursorPosition(CGPointMake(NSMidX(f), top - NSMidY(f)));
        } else if (game_cursor) {
            // Hand the pointer back where the game's cursor is, so the next move doesn't jump.
            os_unfair_lock_lock(&vcur_lock);
            CGPoint p = CGPointMake(vcur_x, vcur_y);
            BOOL known = !CGRectIsEmpty(vcur_bounds);
            os_unfair_lock_unlock(&vcur_lock);
            if (known) CGWarpMouseCursorPosition(p);
        }
        CGAssociateMouseAndMouseCursorPosition(!aiming);
        if (aiming) {
            aim_started = uptime(); atomic_store(&warps_while_aiming, 0);
            dispatch_async(raw_q, ^{ in_last = in_count = in_gaps4 = in_max_gap = 0; memset(in_dev, 0, sizeof in_dev); fs_frames = fs_frames_with_move = 0; });
            os_unfair_lock_lock(&qt_lock); qt_count = qt_sum = qt_max = qt_over4 = qt_over8 = qt_over16 = 0; os_unfair_lock_unlock(&qt_lock);
            note(@"aiming: raw mouse on (%@)", uptime() - atomic_load(&last_game_warp) < 0.5 ? @"game re-centres the cursor" : @"game confines the cursor");
        } else {
            double secs = uptime() - aim_started;
            note(@"aiming: raw mouse off (%.0f s, game moved the cursor %.0f times a second)", secs,
                 secs > 0 ? atomic_load(&warps_while_aiming) / secs : 0.0);
            dispatch_async(raw_q, ^{
                int top = 0; for (int i = 1; i < 4; i++) if (in_dev[i].n > in_dev[top].n) top = i;
                double maxms = (double)in_max_gap * timebase.numer / timebase.denom / 1e6;
                note(@"input: %llu mouse reports (%.0f a second) from %s via %@; longest gap while moving %.1f ms, gaps over 4 ms: %llu",
                     in_count, secs > 0 ? in_count / secs : 0.0, in_dev[top].n ? in_dev[top].name : "?",
                     atomic_load(&hid_active) ? @"hardware" : @"GameController", maxms, in_gaps4);
                os_unfair_lock_lock(&qt_lock);
                uint64_t n = qt_count, sum = qt_sum, mx = qt_max, o4 = qt_over4, o8 = qt_over8, o16 = qt_over16;
                os_unfair_lock_unlock(&qt_lock);
                double f = (double)timebase.numer / timebase.denom / 1e6;
                note(@"frames: %llu during capture, %llu carried movement (%@)", fs_frames, fs_frames_with_move,
                     frame_sync_off ? @"frame sync off" : fs_frames ? @"movement delivered once per frame" : @"no Metal/OpenGL frames seen — delivered as it arrived");
                if (n) note(@"queue: %llu moves; game took them out of Wine's queue after %.2f ms on average, longest %.1f ms; over 4 ms: %llu, over 8 ms: %llu, over 16 ms: %llu",
                            n, sum * f / n, mx * f, o4, o8, o16);
            });
        }
    }
    // Publish (or clear) the window the background queue posts to — only when it changes.
    static __unsafe_unretained NSWindow *published;
    if (w == published) return w;
    published = w;
    void *nw = w ? (void *)CFBridgingRetain(w) : NULL;
    void *nq = w ? (void *)CFBridgingRetain(((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("queue"))) : NULL;
    void *nc = (w && ctl) ? (void *)CFBridgingRetain(ctl) : NULL;
    os_unfair_lock_lock(&target_lock);
    void *ow = target_window, *oq = target_queue, *oc = target_ctl;
    target_window = nw; target_queue = nq; target_ctl = nc;
    atomic_store(&armed, w != nil);
    os_unfair_lock_unlock(&target_lock);
    if (ow) CFRelease(ow);
    if (oq) CFRelease(oq);
    if (oc) CFRelease(oc);
    return w;
}

// Queue timing while capturing: when each of our moves was posted, and how long until the game's thread
// took it out of Wine's event queue (getEventMatchingMask:). Logged when capture ends.

static void qt_posted(void *ev) {
    os_unfair_lock_lock(&qt_lock);
    qt_ring[qt_next++ % 512] = (typeof(qt_ring[0])){ ev, mach_absolute_time() };
    os_unfair_lock_unlock(&qt_lock);
}

static void *my_getEvent(id self, SEL _cmd, uint64_t mask) {
    void *ev = ((void *(*)(id, SEL, uint64_t))orig_getEvent)(self, _cmd, mask);
    if (ev && aiming) {
        uint64_t now = mach_absolute_time();
        os_unfair_lock_lock(&qt_lock);
        for (unsigned i = 0; i < 512; i++) if (qt_ring[i].ev == ev) {
            uint64_t d = now - qt_ring[i].t; qt_ring[i].ev = NULL;
            double ms = (double)d * timebase.numer / timebase.denom / 1e6;
            qt_count++; qt_sum += d; if (d > qt_max) qt_max = d;
            if (ms > 4) qt_over4++; if (ms > 8) qt_over8++; if (ms > 16) qt_over16++;
            break;
        }
        os_unfair_lock_unlock(&qt_lock);
    }
    return ev;
}

static void release_ours(char *ev) {
    // Our reference from creation. The queue holds its own until the game thread has handled it.
    if (atomic_fetch_sub_explicit((_Atomic int *)(ev + kRefs), 1, memory_order_acq_rel) == 1) {
        CFRelease(*(CFTypeRef *)(ev + kWindow));
        free(ev);
    }
}

// Runs on raw_q. Takes its own references to the window/queue so they stay valid while posting.
static void send_relative(int dx, int dy, bool drag) {
    os_unfair_lock_lock(&target_lock);
    void *w = target_window ? (void *)CFRetain(target_window) : NULL;
    void *q = target_queue ? (void *)CFRetain(target_queue) : NULL;
    void *c = target_ctl ? (void *)CFRetain(target_ctl) : NULL;
    os_unfair_lock_unlock(&target_lock);
    if (w && q && c) {
        char *ev = calloc(1, kEventAllocSize);
        if (ev) {
            *(int *)(ev + kRefs) = 1;
            *(int *)(ev + kDeliver) = INT_MAX;
            *(int *)(ev + kType) = relative_type;
            *(void **)(ev + kWindow) = (void *)CFRetain(w);          // owned by the event
            *(int *)(ev + kX) = dx;
            *(int *)(ev + kY) = dy;
            *(int *)(ev + kDrag) = drag;
            *(unsigned long *)(ev + kTime) = ((unsigned long (*)(id, SEL, NSTimeInterval))objc_msgSend)(
                (__bridge id)c, sel_registerName("ticksForEventTime:"), NSProcessInfo.processInfo.systemUptime);
            if (orig_getEvent) qt_posted(ev);
            ((void (*)(id, SEL, void *))orig_postEvent)((__bridge id)q, sel_registerName("postEvent:"), ev);
            release_ours(ev);
            moves_sent++;
            if (game_cursor) {
                os_unfair_lock_lock(&vcur_lock);
                double nx = vcur_x + dx, ny = vcur_y + dy;
                os_unfair_lock_unlock(&vcur_lock);
                vcur_set(nx, ny);
            }
        }
    }
    if (w) CFRelease(w);
    if (q) CFRelease(q);
    if (c) CFRelease(c);
}

static void emit(double dx, double dy) {          // on raw_q
    rest_x += dx;
    rest_y += dy;
    int x = (int)rest_x, y = (int)rest_y;
    if (!x && !y) return;
    rest_x -= x; rest_y -= y;
    send_relative(x, y, NSEvent.pressedMouseButtons != 0);
}

#define STEP_MS 1.0   // smoothing step: at 60 FPS a frame gets 16–17 steps, so frame-to-frame turn varies ~6%
static void smooth_tick(void) {                   // on raw_q, every STEP_MS while there's movement to spread
    if (!atomic_load(&armed) || (pend_x == 0 && pend_y == 0)) {
        pend_x = pend_y = 0;
        if (smooth_running) { dispatch_suspend(smooth_timer); smooth_running = false; }
        return;
    }
    double f = pend_ms <= STEP_MS ? 1 : STEP_MS / pend_ms;
    double ex = pend_x * f, ey = pend_y * f;
    pend_x -= ex; pend_y -= ey; pend_ms = pend_ms > STEP_MS ? pend_ms - STEP_MS : 0;
    if (fabs(pend_x) < 0.01 && fabs(pend_y) < 0.01) { ex += pend_x; ey += pend_y; pend_x = pend_y = 0; }
    emit(ex, ey);
}

static void raw_moved(float dx, float dy) {      // on raw_q
    if (aiming) {                                   // timing stats (reports during continuous movement)
        uint64_t now = mach_absolute_time();
        if (in_last) {
            uint64_t gap = now - in_last;
            double ms = (double)gap * timebase.numer / timebase.denom / 1e6;
            if (ms < 200) { if (gap > in_max_gap) in_max_gap = gap; if (ms > 4) in_gaps4++; }
        }
        in_last = now; in_count++;
    }
    if (!atomic_load(&armed)) { rest_x = rest_y = 0; pend_x = pend_y = 0; fs_x = fs_y = 0; return; }
    if (!frame_sync_off) {
        uint64_t tick = atomic_load(&last_frame_tick), now = mach_absolute_time();
        if (tick && (double)(now - tick) * timebase.numer / timebase.denom < 100e6) {   // frames seen in the last 100 ms
            fs_x += dx * scale; fs_y -= dy * scale;                                     // y: GameController is y-up
            return;
        }
        if (fs_x != 0 || fs_y != 0) { emit(fs_x, fs_y); fs_x = fs_y = 0; }            // frames stopped: flush
    }
    if (smooth_on) {
        uint64_t now = mach_absolute_time();
        if (last_report) {
            double ms = (double)(now - last_report) * timebase.numer / timebase.denom / 1e6;
            if (ms > 0.5 && ms < 25) interval_ms = interval_ms * 0.8 + ms * 0.2;   // the mouse's report rate
        }
        last_report = now;
        // Anything still pending from the previous report goes out now, then spread this one.
        if (pend_x != 0 || pend_y != 0) { emit(pend_x, pend_y); }
        pend_x = dx * scale; pend_y = -dy * scale; pend_ms = interval_ms;
        if (!smooth_running) { dispatch_resume(smooth_timer); smooth_running = true; }
        if (debug_on) { if (stat_last) { uint64_t gap = now - stat_last; if (gap > stat_max_gap) stat_max_gap = gap; } stat_last = now; stat_count++; }
        return;
    }
    if (debug_on) {
        uint64_t now = mach_absolute_time();
        if (stat_last) { uint64_t gap = now - stat_last; if (gap > stat_max_gap) stat_max_gap = gap; }
        stat_last = now; stat_count++;
    }
    rest_x += dx * scale;
    rest_y -= dy * scale;                  // GameController is y-up, Windows y-down
    int x = (int)rest_x, y = (int)rest_y;
    if (!x && !y) return;
    rest_x -= x; rest_y -= y;
    send_relative(x, y, NSEvent.pressedMouseButtons != 0);
}

// MARK: - Swizzled winemac methods

static void my_handleMouseMove(id self, SEL _cmd, NSEvent *event) {
    if (update_aiming(self)) return;      // raw deltas replace pointer-derived moves while aiming
    BOOL learn = relative_type < 0;
    if (learn) { watching_post = YES; watched_location = CGEventGetLocation(event.CGEvent); }
    ((void (*)(id, SEL, NSEvent *))orig_handleMouseMove)(self, _cmd, event);
    if (learn) watching_post = NO;
}

static BOOL my_setCursorPosition(id self, SEL _cmd, CGPoint pos) {
    BOOL ok = ((BOOL (*)(id, SEL, CGPoint))orig_setCursorPosition)(self, _cmd, pos);
    atomic_store(&last_game_warp, uptime());
    if (aiming) atomic_fetch_add(&warps_while_aiming, 1);
    if (aiming) {
        CGAssociateMouseAndMouseCursorPosition(false);   // winemac re-associates after a warp
        if (game_cursor) vcur_set(pos.x, pos.y);         // the game moved its cursor itself
    }
    return ok;
}

// Learns the event layout from a real absolute move posted by winemac, then stops looking.
static void my_postEvent(id self, SEL _cmd, void *raw) {
    if (watching_post && relative_type < 0 && raw) {
        char *ev = raw;
        int refs = *(int *)(ev + kRefs), deliver = *(int *)(ev + kDeliver), type = *(int *)(ev + kType);
        id win = (__bridge id)*(void **)(ev + kWindow);
        int x = *(int *)(ev + kX), y = *(int *)(ev + kY);
        BOOL layout = refs == 1 && deliver == INT_MAX && type > 0 && type < 64 &&
                      win && [win isKindOfClass:objc_getClass("WineWindow")];
        if (layout) {
            // Absolute moves carry the pointer position; relative ones are the type just before.
            BOOL absolute = fabs(x - floor(watched_location.x)) <= 2 && fabs(y - floor(watched_location.y)) <= 2;
            if (absolute) {
                relative_type = type - 1;
                note(@"ready (absolute move type %d, relative %d, scale %.2f, smooth %@, %lu mice)", type, relative_type, scale,
                     smooth_on ? @"on" : @"off", (unsigned long)GCMouse.mice.count);
            } else {
                DEBUG(@"skipped a move event (type %d at %d,%d vs pointer %.0f,%.0f)", type, x, y,
                      watched_location.x, watched_location.y);
            }
        } else {
            note(@"winemac event layout not recognised (refs %d deliver %d type %d) — staying off", refs, deliver, type);
            watching_post = NO;
            relative_type = -2;            // never arm in this process
        }
    }
    // Clicks: check the layout once on a normal click (position = the Mac pointer), then while aiming
    // put each click where the game's cursor is.
    if (game_cursor && raw && relative_type > 0 && *(int *)((char *)raw + kType) == relative_type - 1 && button_layout >= 0) {
        char *ev = raw;
        if (button_layout == 0) {
            CGEventRef e = CGEventCreate(NULL);
            CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
            if (e) CFRelease(e);
            int b = *(int *)(ev + kButton), pr = *(int *)(ev + kPressed), x = *(int *)(ev + kButtonX), y = *(int *)(ev + kButtonY);
            button_layout = (b >= 0 && b < 8 && (pr == 0 || pr == 1) && fabs(x - floor(p.x)) <= 3 && fabs(y - floor(p.y)) <= 3) ? 1 : -1;
            note(@"clicks: %@", button_layout == 1 ? @"layout recognised" : @"layout not recognised — clicks left as they are");
        }
        if (button_layout == 1 && aiming) {
            os_unfair_lock_lock(&vcur_lock);
            *(int *)(ev + kButtonX) = (int)vcur_x;
            *(int *)(ev + kButtonY) = (int)vcur_y;
            os_unfair_lock_unlock(&vcur_lock);
        }
    }
    ((void (*)(id, SEL, void *))orig_postEvent)(self, _cmd, raw);
}

// MARK: - Install

// The mouse hardware itself (IOHID): every report the mouse sends — 1000 a second from a gaming mouse.
// GameController's GCMouse (the fallback) bunches them into ~125 updates a second.
static IOHIDManagerRef hid;
static double hid_dx, hid_dy;                 // raw_q only
static bool hid_flush_pending;                // raw_q only

static void hid_value(__unused void *ctx, __unused IOReturn r, __unused void *sender, IOHIDValueRef v) {   // raw_q
    IOHIDElementRef e = IOHIDValueGetElement(v);
    if (IOHIDElementGetUsagePage(e) != kHIDPage_GenericDesktop) return;
    uint32_t u = IOHIDElementGetUsage(e);
    if (u != kHIDUsage_GD_X && u != kHIDUsage_GD_Y) return;
    if (!IOHIDElementIsRelative(e)) return;
    CFIndex n = IOHIDValueGetIntegerValue(v);
    if (!n) return;
    atomic_store(&hid_active, true);
    if (u == kHIDUsage_GD_X) hid_dx += n; else hid_dy += n;
    if (aiming && u == kHIDUsage_GD_X) {           // which mouse is moving (for the timing note)
        IOHIDDeviceRef d = IOHIDElementGetDevice(e);
        for (int i = 0; i < 4; i++) {
            if (in_dev[i].dev == d) { in_dev[i].n++; break; }
            if (!in_dev[i].dev) {
                in_dev[i].dev = d; in_dev[i].n = 1;
                CFStringRef pn = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
                if (!pn || !CFStringGetCString(pn, in_dev[i].name, sizeof in_dev[i].name, kCFStringEncodingUTF8)) strlcpy(in_dev[i].name, "mouse", sizeof in_dev[i].name);
                break;
            }
        }
    }
    // X and Y of one report arrive back to back; hand them on together.
    if (!hid_flush_pending) {
        hid_flush_pending = true;
        dispatch_async(raw_q, ^{
            hid_flush_pending = false;
            double dx = hid_dx, dy = hid_dy; hid_dx = hid_dy = 0;
            if (dx || dy) raw_moved((float)dx, (float)-dy);   // raw_moved expects GameController's y-up
        });
    }
}

static void start_hid(void) {
    hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *match = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse)},
                       @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Pointer)}];
    IOHIDManagerSetDeviceMatchingMultiple(hid, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterInputValueCallback(hid, hid_value, NULL);
    IOHIDManagerSetDispatchQueue(hid, raw_q);
    IOReturn r = IOHIDManagerOpen(hid, kIOHIDOptionsTypeNone);
    IOHIDManagerActivate(hid);
    note(@"reading the mouse hardware directly%@", r == kIOReturnSuccess ? @"" : [NSString stringWithFormat:@" failed (0x%x) — using GameController", r]);
}

static void watch_mouse(GCMouse *m) {
    m.handlerQueue = raw_q;
    m.mouseInput.mouseMovedHandler = ^(__unused GCMouseInput *input, float dx, float dy) {
        if (!atomic_load(&hid_active)) raw_moved(dx, dy);       // only until the hardware path has delivered
    };
    note(@"mouse: %@", m.vendorName ?: @"(unnamed)");
}

static void frame_tick(void) {                 // any thread, once per frame
    atomic_store(&last_frame_tick, mach_absolute_time());
    if (!aiming || frame_sync_off) return;
    dispatch_async(raw_q, ^{
        fs_frames++;
        if (fs_x == 0 && fs_y == 0) return;
        fs_frames_with_move++;
        double x = fs_x, y = fs_y; fs_x = fs_y = 0;
        emit(x, y);
    });
}

// Low-delay vsync for Metal games (NOKCANDU_METAL_VSYNC=1, Performance → Vsync): frames wait for the screen's
// refresh, so none is shown twice when the game's frame clock drifts against the screen's — but only one
// frame may wait (two drawables), instead of the usual queue of three that makes vsync feel delayed.
static bool metal_vsync;
static IMP orig_setDisplaySync, orig_setMaxDrawables;
static void my_setDisplaySync(id self, SEL _cmd, BOOL on) {
    ((void (*)(id, SEL, BOOL))orig_setDisplaySync)(self, _cmd, metal_vsync ? YES : on);
}
static void my_setMaxDrawables(id self, SEL _cmd, NSUInteger n) {
    ((void (*)(id, SEL, NSUInteger))orig_setMaxDrawables)(self, _cmd, metal_vsync ? 2 : n);
}

static id my_nextDrawable(id self, SEL _cmd) {
    frame_tick();
    if (metal_vsync) {
        static char key;
        if (!objc_getAssociatedObject(self, &key)) {
            objc_setAssociatedObject(self, &key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (orig_setDisplaySync) ((void (*)(id, SEL, BOOL))orig_setDisplaySync)(self, sel_registerName("setDisplaySyncEnabled:"), YES);
            if (orig_setMaxDrawables) ((void (*)(id, SEL, NSUInteger))orig_setMaxDrawables)(self, sel_registerName("setMaximumDrawableCount:"), 2);
            note(@"vsync: frames wait for the screen's refresh (low delay: 2 drawables)");
        }
    }
    return ((id (*)(id, SEL))orig_nextDrawable)(self, _cmd);
}

static BOOL swap(Class c, const char *sel, IMP mine, IMP *orig);
// Frame clock (mouse frame sync) and low-delay vsync: hooks on Metal's layer, for every game.
static void hook_metal_layer(void) {
    static bool done; if (done) return; done = true;
    Class layer = objc_getClass("CAMetalLayer");
    if (!layer) return;
    if (class_getInstanceMethod(layer, sel_registerName("nextDrawable"))) swap(layer, "nextDrawable", (IMP)my_nextDrawable, &orig_nextDrawable);
    if (metal_vsync) {
        if (class_getInstanceMethod(layer, sel_registerName("setDisplaySyncEnabled:")))
            swap(layer, "setDisplaySyncEnabled:", (IMP)my_setDisplaySync, &orig_setDisplaySync);
        if (class_getInstanceMethod(layer, sel_registerName("setMaximumDrawableCount:")))
            swap(layer, "setMaximumDrawableCount:", (IMP)my_setMaxDrawables, &orig_setMaxDrawables);
    }
}

static BOOL swap(Class c, const char *sel, IMP mine, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel_registerName(sel));
    if (!m) return NO;
    *orig = method_setImplementation(m, mine);
    return YES;
}

static void install(void) {
    if (installed) return;
    Class app = objc_getClass("WineApplicationController"), queue = objc_getClass("WineEventQueue");
    Ivar iv = app ? class_getInstanceVariable(app, "clientWantsCursorHidden") : NULL;
    if (!app || !queue || !iv || !objc_getClass("WineWindow") ||
        !class_getInstanceMethod(app, sel_registerName("ticksForEventTime:")) ||
        !class_getInstanceMethod(app, sel_registerName("handleMouseMove:")) ||
        !class_getInstanceMethod(app, sel_registerName("setCursorPosition:")) ||
        !class_getInstanceMethod(queue, sel_registerName("postEvent:")) ||
        !class_getInstanceMethod(objc_getClass("WineWindow"), sel_registerName("queue"))) {
        note(@"this Wine's Mac driver isn't the expected kind — staying off");
        return;
    }
    hidden_ivar = ivar_getOffset(iv);
    swap(app, "handleMouseMove:", (IMP)my_handleMouseMove, &orig_handleMouseMove);
    swap(app, "setCursorPosition:", (IMP)my_setCursorPosition, &orig_setCursorPosition);
    swap(queue, "postEvent:", (IMP)my_postEvent, &orig_postEvent);
    if (class_getInstanceMethod(queue, sel_registerName("getEventMatchingMask:")))
        swap(queue, "getEventMatchingMask:", (IMP)my_getEvent, &orig_getEvent);

    installed = YES;
    start_hid();
    for (GCMouse *m in GCMouse.mice) watch_mouse(m);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { watch_mouse(n.object); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { update_aiming(controller()); }];
    // The game hides/shows its cursor without moving the mouse, so re-check the aiming state often.
    NSTimer *watch = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *t) { update_aiming(controller()); }];
    [NSRunLoop.mainRunLoop addTimer:watch forMode:NSRunLoopCommonModes];
    if (debug_on) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, raw_q);
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(t, ^{
            if (atomic_load(&armed) && stat_count)
                note(@"%lu mouse updates/s, %lu sent/s, longest gap %.1f ms", (unsigned long)(stat_count / 2), moves_sent / 2,
                     (double)stat_max_gap * timebase.numer / timebase.denom / 1e6);
            stat_count = 0; stat_max_gap = 0; stat_last = 0; moves_sent = 0;
        });
        dispatch_resume(t);
        (void)CFBridgingRetain(t);
    }
    note(@"installed; waiting for a mouse move to check winemac's event layout");
}

// MARK: - App name (Dock, Command-Tab, menu bar)
//
// Every Windows program runs inside Wine's own `wine` executable, so macOS calls them all "wine". Nokcandu
// gives each app a list of its programs (NOKCANDU_APP_NAMES: "exe<TAB>Name" lines) and the game's name
// (NOKCANDU_APP_NAME); this sets the real name for the running program.

static NSString *windows_program(void) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return nil;
    char *buf = malloc(size);
    if (!buf) return nil;
    NSString *exe = nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0) {
        char *p = buf + sizeof(int), *end = buf + size;
        p += strnlen(p, end - p);                      // executable path
        while (p < end && *p == '\0') p++;             // padding
        if (p < end) {
            NSString *arg0 = [[NSString alloc] initWithBytes:p length:strnlen(p, end - p) encoding:NSUTF8StringEncoding];
            NSRange r = [arg0 rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/"] options:NSBackwardsSearch];
            exe = (r.location == NSNotFound ? arg0 : [arg0 substringFromIndex:r.location + 1]).lowercaseString;
        }
    }
    free(buf);
    return exe;
}

static NSString *app_name(void) {
    NSString *exe = windows_program();
    const char *list = getenv("NOKCANDU_APP_NAMES");
    if (exe && list) {
        NSString *text = [NSString stringWithContentsOfFile:@(list) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count == 2 && [parts[0] isEqualToString:exe] && [parts[1] length]) return parts[1];
        }
    }
    const char *n = getenv("NOKCANDU_APP_NAME");
    return n && *n ? @(n) : nil;
}

static void set_app_name(NSString *name) {
    void *cs = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    typedef CFTypeRef (*GetASN)(void);
    typedef OSStatus (*SetItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
    GetASN get_asn = cs ? (GetASN)dlsym(cs, "_LSGetCurrentApplicationASN") : NULL;
    SetItem set_item = cs ? (SetItem)dlsym(cs, "_LSSetApplicationInformationItem") : NULL;
    CFStringRef *key = cs ? (CFStringRef *)dlsym(cs, "_kLSDisplayNameKey") : NULL;
    if (get_asn && set_item && key && *key) {
        CFTypeRef asn = get_asn();
        if (asn) {
            set_item(-2, asn, *key, (__bridge CFStringRef)name, NULL);
            // Mark games (not their launchers) as games, so macOS can use Game Mode for them in full screen.
            if (![name isEqualToString:@"Steam"] && ![name isEqualToString:@"Battle.net"]) {
                OSStatus st = set_item(-2, asn, CFSTR("LSApplicationCategoryType"), CFSTR("public.app-category.games"), NULL);
                static bool told;
                if (!told) { told = true; DEBUG(@"game category: %d", (int)st); }
            }
        }
    }
    NSMenuItem *appMenu = NSApp.mainMenu.itemArray.firstObject;
    if (appMenu) { appMenu.submenu.title = name; appMenu.title = name; }
}

static void name_app(void) {
    NSString *name = app_name();
    if (!name) return;
    set_app_name(name);
    // Wine finishes building its menu bar a moment after starting; set the name again once it has.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ set_app_name(name); });
    DEBUG(@"app name: %@", name);
}

// MARK: - Desktop resolution while a fullscreen game is in the background
// A game that picks a fullscreen resolution makes Wine switch the whole display (e.g. to 2560×1600 at 1×,
// where the desktop looks tiny), and Wine keeps that mode until the game quits — even while you're in
// other apps. Put the desktop's own mode back whenever the game goes to the background, and the game's
// mode back when it returns. (Mode changes made by an app are undone by macOS when the app exits.)
static CGDisplayModeRef desktop_mode, game_mode;

static bool same_mode(CGDisplayModeRef a, CGDisplayModeRef b) {
    return CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b) && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b)
        && CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b) && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b);
}

/// Does this app have a window covering the whole main screen (a fullscreen game)?
static bool has_fullscreen_window(void) {
    NSRect screen = NSScreen.screens.firstObject.frame;
    for (NSWindow *w in NSApp.windows)
        if (w.visible && NSContainsRect(w.frame, screen)) return true;
    return false;
}

static void watch_display(NSString *name) {
    // Off unless asked for: switching the display under a running game made CS2 treat it as a lost
    // graphics device (frozen window on alt-tab, video settings reset). Kept for testing only.
    if (!getenv("NOKCANDU_RESTORE_DESKTOP_RESOLUTION")) return;
    // Only the game itself: Steam, Battle.net and unnamed helper programs (overlay, shader cache…) also
    // load this library, and must never touch the display when they go to the background.
    if (!name || [name isEqualToString:@"Steam"] || [name isEqualToString:@"Battle.net"]) return;
    CGDirectDisplayID d = CGMainDisplayID();
    desktop_mode = CGDisplayCopyDisplayMode(d);
    if (!desktop_mode) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
        if (!cur) return;
        // Only when this game changed the display and is showing a fullscreen window.
        if (same_mode(cur, desktop_mode) || !has_fullscreen_window()) { CGDisplayModeRelease(cur); return; }
        if (game_mode) CGDisplayModeRelease(game_mode);
        game_mode = cur;
        CGError e = CGDisplaySetDisplayMode(d, desktop_mode, NULL);
        DEBUG(@"background: desktop resolution back (%zux%zu, error %d)", CGDisplayModeGetWidth(desktop_mode), CGDisplayModeGetHeight(desktop_mode), (int)e);
    }];
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
        if (!game_mode) return;
        CGError e = CGDisplaySetDisplayMode(d, game_mode, NULL);
        DEBUG(@"foreground: game resolution back (%zux%zu, error %d)", CGDisplayModeGetPixelWidth(game_mode), CGDisplayModeGetPixelHeight(game_mode), (int)e);
        CGDisplayModeRelease(game_mode);
        game_mode = NULL;
    }];
}

static void gl_limit_wine(void);
static void restore_pointer(void) { if (aiming) CGAssociateMouseAndMouseCursorPosition(true); }

// MARK: - Hot corners during full-screen play
// macOS hot corners (Mission Control, Quick Note…) fire the instant the pointer touches a corner — in a
// full-screen game with a cursor (Diablo, strategy games) that happens all the time, and moving the pointer
// away afterwards is too late. So while a game is in front and full screen, its hot corners are switched
// off through the Dock's own call, and put back as soon as you switch away, leave full screen or quit.
// The original settings are saved first (Application Support/Nokcandu/hot-corners-saved) so Nokcandu can
// restore them even if a game crashes.
typedef void (*CornerSet)(int action, int corner, int modifier);   // corner: 0 tl, 1 tr, 2 bl, 3 br
static CornerSet corner_set;
static bool corners_off;
static char corners_file[PATH_MAX];

static void read_corners(int act[4], int mod[4]) {
    static const char *keys[4] = { "tl", "tr", "bl", "br" };
    CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
    for (int i = 0; i < 4; i++) {
        char k[32], m[32];
        snprintf(k, sizeof k, "wvous-%s-corner", keys[i]); snprintf(m, sizeof m, "wvous-%s-modifier", keys[i]);
        CFStringRef ck = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8), cm = CFStringCreateWithCString(NULL, m, kCFStringEncodingUTF8);
        CFPropertyListRef a = CFPreferencesCopyAppValue(ck, CFSTR("com.apple.dock")), md = CFPreferencesCopyAppValue(cm, CFSTR("com.apple.dock"));
        act[i] = 0; mod[i] = 0;
        if (a && CFGetTypeID(a) == CFNumberGetTypeID()) CFNumberGetValue(a, kCFNumberIntType, &act[i]);
        if (md && CFGetTypeID(md) == CFNumberGetTypeID()) CFNumberGetValue(md, kCFNumberIntType, &mod[i]);
        if (a) CFRelease(a); if (md) CFRelease(md);
        CFRelease(ck); CFRelease(cm);
    }
}

static void corners_disable(void) {
    if (corners_off || !corner_set) return;
    int act[4], mod[4];
    read_corners(act, mod);
    bool any = false;
    for (int i = 0; i < 4; i++) if (act[i] > 1 && mod[i] == 0) any = true;   // a modifier corner can't fire by accident
    if (!any) return;
    // Keep the first saved copy: another game may already have switched them off.
    int fd = open(corners_file, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        FILE *f = fdopen(fd, "w");
        fprintf(f, "%d\n", (int)getpid());
        for (int i = 0; i < 4; i++) fprintf(f, "%d %d\n", act[i], mod[i]);
        fclose(f);
    } else if (errno != EEXIST) return;                    // can't save them: leave them alone
    for (int i = 0; i < 4; i++) if (act[i] > 1 && mod[i] == 0) corner_set(1, i, 0);
    corners_off = true;
    note(@"hot corners off while the game is in front");
}

static void corners_restore(void) {
    if (!corners_off || !corner_set) return;
    corners_off = false;
    FILE *f = fopen(corners_file, "r");
    if (!f) return;
    int pid = 0, act[4] = {0}, mod[4] = {0}, ok = fscanf(f, "%d", &pid) == 1;
    for (int i = 0; i < 4 && ok; i++) ok = fscanf(f, "%d %d", &act[i], &mod[i]) == 2;
    fclose(f);
    if (!ok) return;
    unlink(corners_file);
    for (int i = 0; i < 4; i++) if (act[i] > 1 && mod[i] == 0) corner_set(act[i], i, mod[i]);
    note(@"hot corners back");
}

static bool is_game_app(void) {
    NSString *cat = NSBundle.mainBundle.infoDictionary[@"LSApplicationCategoryType"];
    return [cat isKindOfClass:NSString.class] && [cat hasPrefix:@"public.app-category."] && [cat hasSuffix:@"games"];
}

static void guard_hot_corners(void) {
    if (getenv("NOKCANDU_ALLOW_HOT_CORNERS") || !is_game_app()) return;
    void *h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    corner_set = h ? (CornerSet)dlsym(h, "CoreDockSetExposeCornerActionWithModifier") : NULL;
    const char *home = getenv("HOME");
    if (!corner_set || !home) return;
    snprintf(corners_file, sizeof corners_file, "%s/Library/Application Support/Nokcandu/hot-corners-saved", home);
    atexit(corners_restore);
    NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        if (NSApp.isActive && has_fullscreen_window()) corners_disable(); else corners_restore();
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { corners_restore(); }];
}

// MARK: - Live settings
// Nokcandu writes the Raw mouse capture settings to "raw-mouse" next to this library (line 1: speed,
// line 2: "smooth"; no file = off). Read it at start and whenever it changes, so switching it on or off
// and changing the speed apply to a running game.
static char settings_path[PATH_MAX];

static bool read_raw_settings(double *sc, bool *sm) {
    FILE *f = settings_path[0] ? fopen(settings_path, "r") : NULL;
    if (!f) return false;
    char l1[64] = "", l2[64] = "";
    if (!fgets(l1, sizeof l1, f)) l1[0] = 0;
    if (!fgets(l2, sizeof l2, f)) l2[0] = 0;
    fclose(f);
    double v = atof(l1);
    *sc = v > 0.01 && v < 20 ? v : 1.0;
    *sm = strncmp(l2, "smooth", 6) == 0;
    return true;
}

static void apply_raw_settings(bool on, double sc, bool sm, bool announce) {
    bool was = atomic_load(&raw_enabled);
    dispatch_async(raw_q, ^{
        if (!sm && (pend_x != 0 || pend_y != 0)) { emit(pend_x, pend_y); pend_x = pend_y = 0; }
        scale = sc; smooth_on = sm;
    });
    atomic_store(&raw_enabled, on);
    if (on && !installed) install();
    if (announce) note(@"raw mouse capture %@ (speed %.2f, smooth %@)", on ? @"on" : @"off", sc, sm ? @"on" : @"off");
    if (was && !on) update_aiming(controller());        // hand the pointer back right away
}

static void watch_settings(void) {
    if (!settings_path[0]) return;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
        static struct timespec last; static bool had, first = true;
        struct stat st;
        bool has = stat(settings_path, &st) == 0;
        if (!first && has == had && (!has || (st.st_mtimespec.tv_sec == last.tv_sec && st.st_mtimespec.tv_nsec == last.tv_nsec))) return;
        if (has) last = st.st_mtimespec;
        had = has;
        bool announce = !first; first = false;
        double sc = 1; bool sm = false;
        bool on = read_raw_settings(&sc, &sm);
        if (announce || on != atomic_load(&raw_enabled)) apply_raw_settings(on, sc, sm, announce);
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}

static void image_added(const struct mach_header *mh, __unused intptr_t slide) {
    Dl_info info;
    static bool seen;
    if (seen || !dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/x86_64-unix/winemac.so")) return;
    seen = true;
    // winemac registers its classes and starts Cocoa after loading; the main queue runs once Cocoa does.
    dispatch_async(dispatch_get_main_queue(), ^{
        name_app();
        gl_limit_wine();
        watch_display(app_name());
        guard_hot_corners();
        hook_metal_layer();
        if (atomic_load(&raw_enabled)) install();
        watch_settings();
    });
}

// MARK: - Sound threads get top priority
// While a game is in front its busy threads take the performance cores, and Wine's sound mixing threads
// (translated by Rosetta) can land on efficiency cores and miss their deadlines — choppy, doubled sound
// that clears up when the game is minimized. Wine names its threads, so raise the sound ones as they start.
#include <pthread.h>
static int my_pthread_setname_np(const char *name) {
    int r = pthread_setname_np(name);
    if (name && (strstr(name, "dsound") || strstr(name, "audio") || strstr(name, "mmdevapi") || strstr(name, "xaudio")
                 || strstr(name, "winmm") || strstr(name, "Miles") || strstr(name, "mss"))) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        note(@"sound thread \"%s\" set to top priority", name);
    }
    return r;
}
__attribute__((used)) static const struct { const void *replacement, *original; } name_interpose[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_pthread_setname_np, (const void *)pthread_setname_np } };

// MARK: - No real-time scheduling for game threads
// Wine's wineserver gives "time critical" Windows threads macOS real-time scheduling. Old games mark their
// busy main or render loop that way; under Rosetta it overruns its real-time slot, the kernel throttles it,
// and everything else — the sound mixer included — stutters while the game is in front. Give those threads
// a strong normal priority instead when NOKCANDU_NO_REALTIME is set (off by default: it did not cure
// BF1942's choppy sound, and CS2 plays well with Wine's normal behaviour).
#include <mach/thread_policy.h>
#include <mach/thread_act.h>
static kern_return_t my_thread_policy_set(thread_act_t thread, thread_policy_flavor_t flavor,
                                          thread_policy_t info, mach_msg_type_number_t count) {
    if (flavor == THREAD_TIME_CONSTRAINT_POLICY && getenv("NOKCANDU_NO_REALTIME")) {
        static bool told;
        if (!told) { told = true; note(@"real-time thread priority replaced with high normal priority"); }
        thread_precedence_policy_data_t p = { .importance = 63 };
        thread_policy_set(thread, THREAD_PRECEDENCE_POLICY, (thread_policy_t)&p, THREAD_PRECEDENCE_POLICY_COUNT);
        return KERN_SUCCESS;
    }
    return thread_policy_set(thread, flavor, info, count);
}
__attribute__((used)) static const struct { const void *replacement, *original; } policy_interpose[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_thread_policy_set, (const void *)thread_policy_set } };

// MARK: - Frame limit for Wine's own OpenGL graphics ("Compatibility")
// Nokcandu's frame limit is DXVK's (DXVK_FRAME_RATE); games drawing through WineD3D/OpenGL ignore it and
// can spin menus at hundreds of FPS, starving their sound. Pace every OpenGL frame to the same limit.
static double gl_fps_limit;
static uint64_t gl_next_frame;            // render thread only
static __thread bool gl_in_flush;

static void frame_tick(void);
static void gl_pace(void) {
    frame_tick();
    if (gl_fps_limit <= 0 || gl_in_flush) return;
    static bool told;
    if (!told) { told = true; note(@"frame limit: pacing OpenGL frames to %.0f FPS", gl_fps_limit); }
    uint64_t period = (uint64_t)(1e9 / gl_fps_limit * timebase.denom / timebase.numer);
    uint64_t now = mach_absolute_time();
    if (gl_next_frame == 0 || now > gl_next_frame + period) gl_next_frame = now;      // first frame, or fell behind
    else if (now < gl_next_frame) mach_wait_until(gl_next_frame);
    gl_next_frame += period;
}

static CGLError my_CGLFlushDrawable(CGLContextObj ctx) {
    gl_pace();
    gl_in_flush = true;
    CGLError e = CGLFlushDrawable(ctx);
    gl_in_flush = false;
    return e;
}
__attribute__((used)) static const struct { const void *replacement, *original; } gl_interpose[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_CGLFlushDrawable, (const void *)CGLFlushDrawable } };

static IMP orig_flushBuffer;
static void my_flushBuffer(id self, SEL _cmd) {
    gl_pace();
    gl_in_flush = true;                    // AppKit may flush through CGLFlushDrawable: pace only once
    ((void (*)(id, SEL))orig_flushBuffer)(self, _cmd);
    gl_in_flush = false;
}

static void gl_limit_setup(void) {
    const char *f = getenv("DXVK_FRAME_RATE");
    gl_fps_limit = f ? atof(f) : 0;
    if (gl_fps_limit < 10 || gl_fps_limit > 1000) { gl_fps_limit = 0; return; }
    Method m = class_getInstanceMethod(objc_getClass("NSOpenGLContext"), sel_registerName("flushBuffer"));
    if (m) orig_flushBuffer = method_setImplementation(m, (IMP)my_flushBuffer);
    note(@"frame limit %.0f FPS armed for OpenGL", gl_fps_limit);
}

/// winemac's own context class may override -flushBuffer; pace that one too (called once winemac loads).
static IMP orig_wine_flushBuffer;
static void my_wine_flushBuffer(id self, SEL _cmd) {
    gl_pace();
    gl_in_flush = true;
    ((void (*)(id, SEL))orig_wine_flushBuffer)(self, _cmd);
    gl_in_flush = false;
}
static void gl_limit_wine(void) {
    if (gl_fps_limit <= 0) return;
    Class c = objc_getClass("WineOpenGLContext");
    if (!c) return;
    unsigned n = 0; Method *list = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++)
        if (method_getName(list[i]) == sel_registerName("flushBuffer")) {
            orig_wine_flushBuffer = method_setImplementation(list[i], (IMP)my_wine_flushBuffer);
            note(@"frame limit: WineOpenGLContext has its own flushBuffer — pacing it");
        }
    free(list);
}

// MARK: - Run as a real app (GameApp wrapper)
// Wine's processes are a bare `wine` program, so macOS shows "wine" and never turns on Game Mode. Nokcandu
// keeps a small app wrapper next to this library (SharedSupport/GameApp/<Name>.app, marked as a game) with a
// copy of the loader in Contents/MacOS. Before Wine starts, relaunch this process from there: same process,
// same arguments and inherited connection to wineserver — but macOS now sees the game's app.
#include <crt_externs.h>
#include <dirent.h>
#include <libgen.h>
#include <unistd.h>
#include <strings.h>
#include <spawn.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
static void run_from_game_app(void) {
    if (getenv("NOKCANDU_NO_GAME_APP")) return;
    char exe[PATH_MAX]; uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || strstr(exe, "/GameApp/")) return;
    const char *base = strrchr(exe, '/');
    if (!base || strcmp(base + 1, "wine") != 0) return;
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    if (argc < 2 || !argv[1] || argv[1][0] == '-' || !argv[1][0]) return;
    // Wine's own background programs stay as they are (no Dock icon, nothing to gain).
    const char *prog = argv[1];
    for (const char *q = argv[1]; *q; q++) if (*q == '\\' || *q == '/') prog = q + 1;
    static const char *skip[] = { "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "explorer.exe",
        "rpcss.exe", "conhost.exe", "start.exe", "wineboot.exe", "winemenubuilder.exe", "rundll32.exe", "tabtip.exe",
        "wineconsole.exe", "regedit.exe", "reg.exe", "msiexec.exe", "cmd.exe", "steamerrorreporter.exe", "steamservice.exe", "gldriverquery.exe", "gldriverquery64.exe",
        "vulkandriverquery.exe", "vulkandriverquery64.exe", "crashhandler.exe", NULL };
    for (int i = 0; skip[i]; i++) if (strcasecmp(prog, skip[i]) == 0) return;
    Dl_info info;
    if (!dladdr((const void *)run_from_game_app, &info) || !info.dli_fname) return;
    char me[PATH_MAX], dir[PATH_MAX], list[PATH_MAX];
    strlcpy(me, info.dli_fname, sizeof me);
    snprintf(dir, sizeof dir, "%s/../GameApp", dirname(me));
    snprintf(list, sizeof list, "%s/programs.tsv", dir);
    // programs.tsv: "<program.exe>\t<Wrapper>.app" lines, and "*\t<Wrapper>.app" for everything else.
    char wrapper[NAME_MAX + 1] = "", fallback[NAME_MAX + 1] = "", engine[64] = "", line[1024];
    FILE *f = fopen(list, "r");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *tab = strchr(line, '\t');
        if (!tab || !tab[1]) continue;
        *tab = 0;
        if (strcmp(line, "#engine") == 0) strlcpy(engine, tab + 1, sizeof engine);
        else if (strcmp(line, "*") == 0) strlcpy(fallback, tab + 1, sizeof fallback);
        else if (strcasecmp(line, prog) == 0) strlcpy(wrapper, tab + 1, sizeof wrapper);
    }
    fclose(f);
    if (!wrapper[0]) strlcpy(wrapper, fallback, sizeof wrapper);
    // Only use wrappers made for this engine (Nokcandu refreshes them after an engine update).
    char real[PATH_MAX], want[64];
    struct stat st;
    snprintf(real, sizeof real, "%s/../wine/bin/wine", dir);
    if (!engine[0] || stat(real, &st) != 0) return;
    snprintf(want, sizeof want, "%lld:%lld", (long long)st.st_size, (long long)st.st_mtimespec.tv_sec);
    if (strcmp(want, engine) != 0) return;
    if (!wrapper[0] || strchr(wrapper, '/')) return;
    char target[PATH_MAX];
    snprintf(target, sizeof target, "%s/%s/Contents/MacOS/wine", dir, wrapper);
    if (access(target, X_OK) != 0) return;
    // Replace this process in place, like exec. It stays in the care of the app that started it, so it
    // keeps that app's privacy permissions (Input Monitoring for raw mouse, the microphone) — making the game
    // responsible for itself made macOS refuse raw mouse access (0xe00002e2) without asking.
    execv(target, argv);                       // only returns on failure: carry on as bare wine
}

__attribute__((constructor)) static void start(void) {
    run_from_game_app();
    const char *s = getenv("NOKCANDU_RAW_MOUSE_SCALE");
    if (s && atof(s) > 0.01 && atof(s) < 20) scale = atof(s);
    Dl_info self;
    if (dladdr((const void *)start, &self) && self.dli_fname) {
        char me[PATH_MAX]; strlcpy(me, self.dli_fname, sizeof me);
        snprintf(settings_path, sizeof settings_path, "%s/raw-mouse", dirname(me));
    }
    debug_on = getenv("NOKCANDU_RAW_MOUSE_DEBUG") != NULL;
    game_cursor = getenv("NOKCANDU_RAW_MOUSE_GAME_CURSOR") != NULL;
    metal_vsync = getenv("NOKCANDU_METAL_VSYNC") && strcmp(getenv("NOKCANDU_METAL_VSYNC"), "1") == 0;
    frame_sync_off = getenv("NOKCANDU_RAW_MOUSE_FRAME_SYNC") && strcmp(getenv("NOKCANDU_RAW_MOUSE_FRAME_SYNC"), "0") == 0;
    atomic_store(&raw_enabled, getenv("NOKCANDU_RAW_MOUSE_SCALE") != NULL);
    mach_timebase_info(&timebase);
    gl_limit_setup();
    raw_q = dispatch_queue_create("nokcandu.rawmouse", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    smooth_on = getenv("NOKCANDU_RAW_MOUSE_SMOOTH") && atoi(getenv("NOKCANDU_RAW_MOUSE_SMOOTH")) == 1;
    { double sc; bool sm;                 // the settings file wins over the launcher's copy of it
      if (read_raw_settings(&sc, &sm)) { scale = sc; smooth_on = sm; atomic_store(&raw_enabled, true); }
      else if (settings_path[0]) atomic_store(&raw_enabled, false); }
    {   // created suspended; smoothing can be switched on while playing
        smooth_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, raw_q);
        dispatch_source_set_timer(smooth_timer, DISPATCH_TIME_NOW, (uint64_t)(STEP_MS * NSEC_PER_MSEC), 100 * NSEC_PER_USEC);
        dispatch_source_set_event_handler(smooth_timer, ^{ smooth_tick(); });
    }
    atexit(restore_pointer);
    _dyld_register_func_for_add_image(image_added);
}
