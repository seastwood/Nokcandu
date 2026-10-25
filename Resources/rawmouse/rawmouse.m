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
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Layout of winemac's event header and mouse-move payload (Wine's macdrv_cocoa.h), verified at runtime.
enum { kRefs = 0x0, kDeliver = 0x4, kType = 0x8, kWindow = 0x10, kX = 0x18, kY = 0x1c, kDrag = 0x20, kTime = 0x28 };
enum { kEventAllocSize = 256 };

static IMP orig_handleMouseMove, orig_setCursorPosition, orig_postEvent;
static ptrdiff_t hidden_ivar = -1;
static double scale = 1.0, rest_x, rest_y;
static int relative_type = -1;           // learned from winemac's own absolute-move events
static BOOL watching_post, aiming, debug_on, installed;
static CGPoint watched_location;
static unsigned long moves_sent;

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

// The game window while the game is in mouse-look: our app is active, the Windows cursor is hidden,
// a mouse is connected and the layout check has passed.
static NSWindow *aim_window(id ctl) {
    if (relative_type < 0 || !ctl || !NSApp.isActive || GCMouse.mice.count == 0 || hidden_ivar < 0) return nil;
    BOOL hidden = *(BOOL *)((char *)(__bridge void *)ctl + hidden_ivar);
    if (!hidden) return nil;
    NSWindow *w = NSApp.keyWindow;
    return [w isKindOfClass:objc_getClass("WineWindow")] ? w : nil;
}

static NSWindow *update_aiming(id ctl) {
    NSWindow *w = aim_window(ctl);
    BOOL now = w != nil;
    if (now != aiming) {
        aiming = now;
        rest_x = rest_y = 0;
        if (aiming) {
            // Park the frozen pointer in the middle of the game so clicks land there.
            NSRect f = w.frame;
            CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
            CGWarpMouseCursorPosition(CGPointMake(NSMidX(f), top - NSMidY(f)));
        }
        CGAssociateMouseAndMouseCursorPosition(!aiming);
        note(@"%@", aiming ? @"aiming: raw mouse on" : @"aiming: raw mouse off");
    }
    return w;
}

static void release_ours(char *ev) {
    // Our reference from creation. The queue holds its own until the game thread has handled it.
    if (atomic_fetch_sub_explicit((_Atomic int *)(ev + kRefs), 1, memory_order_acq_rel) == 1) {
        CFRelease(*(CFTypeRef *)(ev + kWindow));
        free(ev);
    }
}

static void send_relative(NSWindow *w, id ctl, int dx, int dy) {
    char *ev = calloc(1, kEventAllocSize);
    if (!ev) return;
    *(int *)(ev + kRefs) = 1;
    *(int *)(ev + kDeliver) = INT_MAX;
    *(int *)(ev + kType) = relative_type;
    *(void **)(ev + kWindow) = (void *)CFBridgingRetain(w);
    *(int *)(ev + kX) = dx;
    *(int *)(ev + kY) = dy;
    *(int *)(ev + kDrag) = NSEvent.pressedMouseButtons != 0;
    *(unsigned long *)(ev + kTime) = ((unsigned long (*)(id, SEL, NSTimeInterval))objc_msgSend)(
        ctl, sel_registerName("ticksForEventTime:"), NSProcessInfo.processInfo.systemUptime);
    id queue = ((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("queue"));
    ((void (*)(id, SEL, void *))orig_postEvent)(queue, sel_registerName("postEvent:"), ev);
    release_ours(ev);
    moves_sent++;
}

static void raw_moved(float dx, float dy) {
    id ctl = controller();
    NSWindow *w = update_aiming(ctl);
    if (!w) return;
    rest_x += dx * scale;
    rest_y -= dy * scale;                  // GameController is y-up, Windows y-down
    int x = (int)rest_x, y = (int)rest_y;
    if (!x && !y) return;
    rest_x -= x; rest_y -= y;
    send_relative(w, ctl, x, y);
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
    if (aiming) CGAssociateMouseAndMouseCursorPosition(false);   // winemac re-associates after a warp
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
                note(@"ready (absolute move type %d, relative %d, scale %.2f, %lu mice)", type, relative_type, scale,
                     (unsigned long)GCMouse.mice.count);
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
    ((void (*)(id, SEL, void *))orig_postEvent)(self, _cmd, raw);
}

// MARK: - Install

static void watch_mouse(GCMouse *m) {
    m.handlerQueue = dispatch_get_main_queue();
    m.mouseInput.mouseMovedHandler = ^(__unused GCMouseInput *input, float dx, float dy) { raw_moved(dx, dy); };
    note(@"mouse: %@", m.vendorName ?: @"(unnamed)");
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
    installed = YES;
    for (GCMouse *m in GCMouse.mice) watch_mouse(m);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { watch_mouse(n.object); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { update_aiming(controller()); }];
    if (debug_on) {
        [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer *t) {
            if (aiming) note(@"%lu moves/s while aiming", moves_sent / 2);
            moves_sent = 0;
        }];
    }
    note(@"installed; waiting for a mouse move to check winemac's event layout");
}

static void restore_pointer(void) { if (aiming) CGAssociateMouseAndMouseCursorPosition(true); }

static void image_added(const struct mach_header *mh, __unused intptr_t slide) {
    Dl_info info;
    if (installed || !dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/x86_64-unix/winemac.so")) return;
    // winemac registers its classes and starts Cocoa after loading; the main queue runs once Cocoa does.
    dispatch_async(dispatch_get_main_queue(), ^{ install(); });
}

__attribute__((constructor)) static void start(void) {
    const char *s = getenv("NOKCANDU_RAW_MOUSE_SCALE");
    if (s && atof(s) > 0.01 && atof(s) < 20) scale = atof(s);
    debug_on = getenv("NOKCANDU_RAW_MOUSE_DEBUG") != NULL;
    atexit(restore_pointer);
    _dyld_register_func_for_add_image(image_added);
}
