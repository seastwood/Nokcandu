// Nokcandu presentation prototype: show a fullscreen Wine game inside a movable, resizable Mac window.
//
// The game keeps its full-size window (Wine and the game see no change). The window server draws it scaled
// into a normal Mac window ("the frame"), using the window transform macOS uses for its own window effects:
// no copying, the GPU composites it. Transformed windows don't receive clicks, so the frame window receives
// the mouse and this library rewrites each mouse event into the game's own coordinates before Wine sees it.
// Enabled with NOKCANDU_PRESENT=1 (optional NOKCANDU_PRESENT_SIZE=WxH for the first window size, in points).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include "geometry.h"

typedef int SLSConnection;
static CGError (*SLSSetWindowTransform)(SLSConnection, uint32_t, CGAffineTransform);
static SLSConnection (*SLSMainConnectionID)(void);
static CGError (*SLSAddWindowToWindowOrderingGroup)(SLSConnection, uint32_t parent, uint32_t child, int order);
static CGError (*SLSRemoveFromOrderingGroup)(SLSConnection, uint32_t window);

static FILE *logf_;
static void note(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void note(NSString *fmt, ...) {
    if (!logf_) { const char *p = getenv("NOKCANDU_PRESENT_LOG"); logf_ = fopen(p ? p : "/tmp/nokcandu-present.log", "a"); if (!logf_) return; }
    va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    fprintf(logf_, "%d %s\n", getpid(), s.UTF8String); fflush(logf_);
}

/// The frame's content: black bars where the window's shape differs from the game's, a see-through hole where
/// the game's picture shows from below.
@interface NokPresentContent : NSView
@property NSRect hole;      // in this view's coordinates
@end
@implementation NokPresentContent
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.blackColor setFill];
    NSRectFill(dirty);
    NSRectFillUsingOperation(NSIntersectionRect(dirty, NSInsetRect(self.hole, -0.5, -0.5)), NSCompositingOperationClear);
}
@end

/// The frame never takes keyboard focus: the game's own window stays the key window, so keys reach the game.
@interface NokPresentFrame : NSWindow
@end
@implementation NokPresentFrame
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSWindow *frameWindow;          // the Mac window the player moves and resizes
static __weak NSWindow *gameWindow;    // the game's fullscreen Wine window
static NokPresentGeometry geo;         // published on the main thread; read by the event rewrite (same thread)
static void selfTest(void);
static void tieToFrame(void);
static BOOL confining;              // the pointer is kept inside the picture right now
static CGRect gameClip;             // the game's ClipCursor area, in the game's coordinates (empty: none)
static BOOL manualCapture;          // Control-Command-Escape: keep the pointer in the picture until pressed again
static void (*orig_orderRelative)(id, SEL, NSWindowOrderingMode, NSInteger);
static NSView *titlebarFill;
static void updateCapture(void);
static BOOL filling;
static BOOL enabled;
static NSSize firstSize;

static CGFloat primaryHeight(void) { return CGDisplayBounds(CGMainDisplayID()).size.height; }
// Cocoa (bottom-left origin) <-> global top-left points.
static CGRect toTopLeft(NSRect r) { return CGRectMake(r.origin.x, primaryHeight() - NSMaxY(r), r.size.width, r.size.height); }

// MARK: Virtual display
// The game sees one monitor of its own size (a fixed internal resolution, or whatever mode it switches to);
// the Mac's screen never changes. Only Wine's Mac driver is shown the virtual monitor: calls are answered by
// who makes them (winemac.so), so AppKit and this library keep seeing the real screen.
static CGFloat virtW, virtH;                 // 0: the real screen
static CGDisplayModeRef virtMode;            // the mode the game picked (real or one of the carriers below)
static NSMutableDictionary<NSValue *, NSValue *> *carrierSizes;   // carrier mode -> the size it stands for
static NSArray *carriers;

static BOOL fromWine(void *ret) {
    static const struct mach_header *wineImage;
    if (!wineImage) {
        for (uint32_t i = 0; i < _dyld_image_count(); i++)
            if (strstr(_dyld_get_image_name(i), "winemac.so")) { wineImage = _dyld_get_image_header(i); break; }
        if (!wineImage) return NO;
    }
    Dl_info info;
    return dladdr(ret, &info) && info.dli_fbase == wineImage;
}
/// Height Wine flips its coordinates with (its idea of the primary screen).
static CGFloat wineHeight(void) { return virtW > 0 ? virtH : primaryHeight(); }
/// A Cocoa rect in the game's own (Windows) coordinates.
static CGRect toWin(NSRect r) { return CGRectMake(r.origin.x, wineHeight() - NSMaxY(r), r.size.width, r.size.height); }

static BOOL carrierSize(CGDisplayModeRef m, CGSize *size) {
    NSValue *v = m ? carrierSizes[[NSValue valueWithPointer:m]] : nil;
    if (v && size) *size = v.sizeValue;
    return v != nil;
}

/// Standard game resolutions, each carried by one real (otherwise unused) display mode object.
static void makeCarriers(void) {
    if (carriers) return;
    NSDictionary *opts = @{ (NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    NSArray *real = CFBridgingRelease(CGDisplayCopyAllDisplayModes(CGMainDisplayID(), (__bridge CFDictionaryRef)opts));
    int sizes[][2] = { {640,480}, {800,600}, {1024,768}, {1152,864}, {1280,720}, {1280,800}, {1280,960}, {1280,1024},
                       {1366,768}, {1440,900}, {1600,900}, {1600,1200}, {1680,1050}, {1920,1080}, {1920,1200}, {2560,1440} };
    const char *want = getenv("NOKCANDU_PRESENT_RESOLUTION");
    int ww = 0, wh = 0; if (want) sscanf(want, "%dx%d", &ww, &wh);
    carrierSizes = [NSMutableDictionary dictionary];
    NSMutableArray *list = [NSMutableArray array];
    NSUInteger n = 0;
    for (unsigned i = 0; i <= sizeof sizes / sizeof sizes[0] && n < real.count; i++) {
        int w = i < sizeof sizes / sizeof sizes[0] ? sizes[i][0] : ww, h = i < sizeof sizes / sizeof sizes[0] ? sizes[i][1] : wh;
        if (w <= 0 || h <= 0) continue;
        if (i == sizeof sizes / sizeof sizes[0]) { BOOL dup = NO; for (unsigned j = 0; j < i; j++) if (sizes[j][0] == w && sizes[j][1] == h) dup = YES; if (dup) continue; }
        id carrier = real[n++];
        carrierSizes[[NSValue valueWithPointer:(__bridge void *)carrier]] = [NSValue valueWithSize:NSMakeSize(w, h)];
        [list addObject:carrier];
    }
    carriers = list;
}

static CGDisplayModeRef carrierFor(int w, int h) {
    makeCarriers();
    for (id c in carriers) { CGSize s; if (carrierSize((__bridge CGDisplayModeRef)c, &s) && s.width == w && s.height == h) return (__bridge CGDisplayModeRef)c; }
    return NULL;
}

// Every Wine process of the game has to agree on the display (the desktop window, the game, its helpers): the
// mode lives in a small file in the Wine prefix that all of them watch.
static NSString *sharedModePath(void) {
    const char *pfx = getenv("WINEPREFIX");
    return pfx ? [[NSString stringWithUTF8String:pfx] stringByAppendingPathComponent:@".nokcandu-virtual-display"] : nil;
}
static void writeSharedMode(CGFloat w, CGFloat h) {
    NSString *path = sharedModePath(); if (!path) return;
    [[NSString stringWithFormat:@"%.0fx%.0f\n", w, h] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL readSharedMode(int *w, int *h) {
    NSString *t = [NSString stringWithContentsOfFile:sharedModePath() encoding:NSUTF8StringEncoding error:nil];
    return t && sscanf(t.UTF8String, "%dx%d", w, h) == 2;
}

static void displaysChanged(void) {
    // Wine re-reads monitors and modes on this notification (and tells the game, WM_DISPLAYCHANGE).
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
}

static void setVirtualMode(CGDisplayModeRef m) {
    CGSize s = CGSizeZero;
    if (m && !carrierSize(m, &s)) s = CGSizeMake(CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m));
    CGRect real = CGDisplayBounds(CGMainDisplayID());
    if (!m || (s.width == real.size.width && s.height == real.size.height)) { virtW = virtH = 0; virtMode = NULL; }
    else { virtW = s.width; virtH = s.height; virtMode = m; }
    note(@"virtual display %.0fx%.0f", virtW, virtH);
}

// NSScreen, asked by Wine: one screen, the virtual one.
static NSRect (*orig_screenFrame)(id, SEL);
static NSRect my_screenFrame(NSScreen *self, SEL _cmd) {
    if (virtW > 0 && fromWine(__builtin_return_address(0)) && self == NSScreen.screens.firstObject) return NSMakeRect(0, 0, virtW, virtH);
    return orig_screenFrame(self, _cmd);
}
static NSRect (*orig_screenVisible)(id, SEL);
static NSRect my_screenVisible(NSScreen *self, SEL _cmd) {
    if (virtW > 0 && fromWine(__builtin_return_address(0)) && self == NSScreen.screens.firstObject) return NSMakeRect(0, 0, virtW, virtH);
    return orig_screenVisible(self, _cmd);
}
static NSArray *(*orig_screens)(id, SEL);
static NSArray *my_screens(id self, SEL _cmd) {
    NSArray *a = orig_screens(self, _cmd);
    if (virtW > 0 && fromWine(__builtin_return_address(0)) && a.count > 1) return @[a.firstObject];
    return a;
}

// Display modes, asked by Wine.
static BOOL presenting(void) { return enabled; }
static CFArrayRef my_CopyAllModes(CGDirectDisplayID d, CFDictionaryRef o) {
    if (presenting() && fromWine(__builtin_return_address(0)) && d == CGMainDisplayID()) { makeCarriers(); return (CFArrayRef)CFBridgingRetain(carriers); }
    return CGDisplayCopyAllDisplayModes(d, o);
}
static CGDisplayModeRef my_CopyMode(CGDirectDisplayID d) {
    if (virtMode && fromWine(__builtin_return_address(0)) && d == CGMainDisplayID()) return CGDisplayModeRetain(virtMode);
    return CGDisplayCopyDisplayMode(d);
}
static CGError my_SetMode(CGDirectDisplayID d, CGDisplayModeRef m, CFDictionaryRef o) {
    if (presenting() && fromWine(__builtin_return_address(0))) {
        setVirtualMode(m);
        dispatch_async(dispatch_get_main_queue(), ^{ displaysChanged(); });
        return kCGErrorSuccess;            // the Mac's screen stays as it is
    }
    return CGDisplaySetDisplayMode(d, m, o);
}
// Wine's own entry point for a game's display-mode change (it would capture the displays and switch the Mac's
// screen, or delay it while the app isn't active): the virtual display takes the mode at once.
static BOOL (*orig_setModeForDisplay)(id, SEL, CGDisplayModeRef, CGDirectDisplayID);
static BOOL my_setModeForDisplay(id self, SEL _cmd, CGDisplayModeRef m, CGDirectDisplayID d) {
    if (!presenting() || d != CGMainDisplayID()) return orig_setModeForDisplay(self, _cmd, m, d);
    setVirtualMode(m);
    CGRect real = CGDisplayBounds(CGMainDisplayID());
    writeSharedMode(virtW > 0 ? virtW : real.size.width, virtW > 0 ? virtH : real.size.height);
    dispatch_async(dispatch_get_main_queue(), ^{ displaysChanged(); });
    return YES;
}
static CGError my_CaptureAll(void) { if (presenting() && fromWine(__builtin_return_address(0))) return kCGErrorSuccess; return CGCaptureAllDisplays(); }
static CGError my_ReleaseAll(void) { if (presenting() && fromWine(__builtin_return_address(0))) return kCGErrorSuccess; return CGReleaseAllDisplays(); }
static void my_Restore(void) {
    if (presenting() && fromWine(__builtin_return_address(0))) { setVirtualMode(NULL); dispatch_async(dispatch_get_main_queue(), ^{ displaysChanged(); }); return; }
    CGRestorePermanentDisplayConfiguration();
}
static size_t my_ModeW(CGDisplayModeRef m) { CGSize s; return carrierSize(m, &s) ? (size_t)s.width : CGDisplayModeGetWidth(m); }
static size_t my_ModeH(CGDisplayModeRef m) { CGSize s; return carrierSize(m, &s) ? (size_t)s.height : CGDisplayModeGetHeight(m); }
static size_t my_ModePW(CGDisplayModeRef m) { CGSize s; return carrierSize(m, &s) ? (size_t)s.width : CGDisplayModeGetPixelWidth(m); }
static size_t my_ModePH(CGDisplayModeRef m) { CGSize s; return carrierSize(m, &s) ? (size_t)s.height : CGDisplayModeGetPixelHeight(m); }
static bool my_ModeUsable(CGDisplayModeRef m) { return carrierSize(m, NULL) ? true : CGDisplayModeIsUsableForDesktopGUI(m); }
__attribute__((used)) static const struct { const void *replacement, *original; } display_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_CopyAllModes, (const void *)CGDisplayCopyAllDisplayModes },
    { (const void *)my_CopyMode, (const void *)CGDisplayCopyDisplayMode },
    { (const void *)my_SetMode, (const void *)CGDisplaySetDisplayMode },
    { (const void *)my_CaptureAll, (const void *)CGCaptureAllDisplays },
    { (const void *)my_ReleaseAll, (const void *)CGReleaseAllDisplays },
    { (const void *)my_Restore, (const void *)CGRestorePermanentDisplayConfiguration },
    { (const void *)my_ModeW, (const void *)CGDisplayModeGetWidth },
    { (const void *)my_ModeH, (const void *)CGDisplayModeGetHeight },
    { (const void *)my_ModePW, (const void *)CGDisplayModeGetPixelWidth },
    { (const void *)my_ModePH, (const void *)CGDisplayModeGetPixelHeight },
    { (const void *)my_ModeUsable, (const void *)CGDisplayModeIsUsableForDesktopGUI },
};

static BOOL isWineWindow(NSWindow *w) { return w && w != frameWindow && [NSStringFromClass(w.class) hasPrefix:@"Wine"]; }

/// The window server transform for one Wine window: shows the whole Wine desktop region scaled into the frame.
static void applyTransforms(void) {
    if (!SLSSetWindowTransform) return;
    for (NSWindow *w in NSApp.windows) {
        if (!isWineWindow(w) || !w.isVisible) continue;
        // The window server still hit-tests a transformed window by its untransformed shape: let the mouse
        // pass through to the frame below (this library hands each event to the game itself).
        if (!w.ignoresMouseEvents) w.ignoresMouseEvents = YES;
        NokPresentGeometry real = geo;          // the window server works in real screen coordinates
        real.game = toTopLeft(gameWindow.frame);
        CGAffineTransform m = nok_present_window_transform(&real, toTopLeft(w.frame));
        CGError e = SLSSetWindowTransform(SLSMainConnectionID(), (uint32_t)w.windowNumber, m);
        if (e) note(@"transform window %ld failed %d", (long)w.windowNumber, e);
    }
}

/// A thin border around the picture belongs to the frame: grab it to resize (the picture itself stays the game's,
/// edge to edge, so buttons at the game's edges keep working).
static CGFloat padding(void) { return 0; }

static void updateGeometry(void) {
    NSWindow *g = gameWindow;
    if (!g || !frameWindow) return;
    // The game switched resolution (a new shape): the window takes the new shape, keeping its width.
    static NSSize lastGame;
    if (!NSEqualSizes(lastGame, g.frame.size)) {
        BOOL first = lastGame.width == 0;
        lastGame = g.frame.size;
        frameWindow.contentAspectRatio = lastGame;
        if (!first && !filling && !(frameWindow.styleMask & NSWindowStyleMaskFullScreen)) {
            NSRect c = [frameWindow contentRectForFrameRect:frameWindow.frame];
            CGFloat h = c.size.width * lastGame.height / lastGame.width;
            c.origin.y += c.size.height - h; c.size.height = h;          // keep the top edge in place
            [frameWindow setFrame:[frameWindow frameRectForContentRect:c] display:YES];
        }
    }
    NSRect content = [frameWindow contentRectForFrameRect:frameWindow.frame];
    CGFloat pad = padding();
    nok_present_update(&geo, toWin(g.frame), CGRectInset(toTopLeft(content), pad, pad));
    NokPresentContent *v = (NokPresentContent *)frameWindow.contentView;
    if ([v isKindOfClass:NokPresentContent.class] && geo.valid) {
        CGFloat h = primaryHeight();
        NSRect screenHole = NSMakeRect(geo.display.origin.x, h - CGRectGetMaxY(geo.display), geo.display.size.width, geo.display.size.height);
        NSRect hole = [v convertRect:[frameWindow convertRectFromScreen:screenHole] fromView:nil];
        if (!NSEqualRects(hole, v.hole)) { v.hole = hole; v.needsDisplay = YES; }
    }
    applyTransforms();
}

@interface NokPresentDelegate : NSObject <NSWindowDelegate>
@end
@implementation NokPresentDelegate
- (void)windowDidResize:(NSNotification *)n { updateGeometry(); }
- (void)windowDidMove:(NSNotification *)n { updateGeometry(); }
- (void)windowDidMiniaturize:(NSNotification *)n {
    for (NSWindow *w in NSApp.windows) if (isWineWindow(w) && w.isVisible) w.alphaValue = 0;
}
- (void)windowDidDeminiaturize:(NSNotification *)n {
    for (NSWindow *w in NSApp.windows) if (isWineWindow(w)) w.alphaValue = 1;
    updateGeometry();
}
static NSWindowCollectionBehavior savedBehavior;
// The title bar macOS slides down in full screen is its own window; keep it above the game's window.
static void raiseTitlebar(void) {
    for (NSWindow *w in NSApp.windows)
        if ([NSStringFromClass(w.class) containsString:@"FullScreen"] && ![NSStringFromClass(w.class) containsString:@"Transition"] && w.level <= NSFloatingWindowLevel)
            w.level = NSFloatingWindowLevel + 1;
}
- (void)windowWillEnterFullScreen:(NSNotification *)n {
    NSWindow *g = gameWindow; if (!g) return;
    savedBehavior = g.collectionBehavior;
    g.collectionBehavior = (savedBehavior | NSWindowCollectionBehaviorFullScreenAuxiliary) & ~NSWindowCollectionBehaviorTransient;
}
- (void)windowDidEnterFullScreen:(NSNotification *)n {
    filling = YES;
    titlebarFill.hidden = YES;            // in full screen macOS draws its own title bar when it slides down
    raiseTitlebar();
    updateGeometry();
}
- (void)windowDidExitFullScreen:(NSNotification *)n {
    filling = NO;
    titlebarFill.hidden = NO;
    NSWindow *g = gameWindow; if (!g) return;
    g.collectionBehavior = savedBehavior;
    tieToFrame();
    updateGeometry();
}
- (BOOL)windowShouldClose:(NSWindow *)w {
    // Closing the frame asks the game to close, like its own window's close box would.
    NSWindow *g = gameWindow; if (g) [g performClose:nil];
    return NO;
}
@end
static NokPresentDelegate *delegate;

/// The window server keeps the game's window directly below the frame (in the window order and across Spaces,
/// like a child window) without AppKit moving it along when the frame moves.
static void tieToFrame(void) {
    NSWindow *g = gameWindow; if (!g || !frameWindow) return;
    // Only the frame is "the window" for Mission Control, App Exposé and Command-`: the game's own window is
    // part of it, not a second window of its own.
    if (orig_orderRelative) orig_orderRelative(g, @selector(orderWindow:relativeTo:), NSWindowBelow, frameWindow.windowNumber);
    else [g orderWindow:NSWindowBelow relativeTo:frameWindow.windowNumber];
    NSWindowCollectionBehavior b = g.collectionBehavior | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    b &= ~(NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle);
    if (g.collectionBehavior != b) g.collectionBehavior = b;
    if (SLSAddWindowToWindowOrderingGroup) {
        CGError e = SLSAddWindowToWindowOrderingGroup(SLSMainConnectionID(), (uint32_t)frameWindow.windowNumber, (uint32_t)g.windowNumber, -1);
        static CGError last = -99; if (e != last) { note(@"ordering group: %d", e); last = e; }
    }
}

/// A solid title bar: the frame's content is see-through (the game shows from below), the title bar must not be.
static void solidTitlebar(void) {
    NSView *theme = frameWindow.contentView.superview;
    NSView *bar = nil;
    for (NSView *v in theme.subviews) if ([NSStringFromClass(v.class) containsString:@"Titlebar"]) bar = v;
    if (!bar) return;
    NSBox *fill = [[NSBox alloc] initWithFrame:bar.frame];
    fill.boxType = NSBoxCustom; fill.borderWidth = 0; fill.fillColor = NSColor.windowBackgroundColor;
    fill.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [theme addSubview:fill positioned:NSWindowBelow relativeTo:bar];
    titlebarFill = fill;
}

// MARK: Full screen
// A separate macOS full-screen Space would leave the game's own window behind on the desktop (it has to stay
// where Wine put it), so full screen here fills the screen on the same Space: no title bar, menu bar and Dock
// hidden until the pointer reaches them. The green button, Control-Command-F and Window > Exit Full Screen
// switch it.
static NSRect savedFrame;
static BOOL nativeFS(void) { const char *v = getenv("NOKCANDU_PRESENT_NATIVEFS"); return !v || *v != '0'; }
static void setFilling(BOOL on) {
    if (nativeFS()) { if (on != ((frameWindow.styleMask & NSWindowStyleMaskFullScreen) != 0)) [frameWindow toggleFullScreen:nil]; return; }
    if (on == filling || !frameWindow) return;
    filling = on;
    if (on) {
        savedFrame = frameWindow.frame;
        NSApp.presentationOptions = NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock;
        frameWindow.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
        [frameWindow setFrame:(frameWindow.screen ?: NSScreen.mainScreen).frame display:YES];
    } else {
        NSApp.presentationOptions = NSApplicationPresentationDefault;
        frameWindow.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        [frameWindow setFrame:savedFrame display:YES];
        frameWindow.title = NSProcessInfo.processInfo.processName;
    }
    updateGeometry();
    note(@"full screen %d", on);
}

@interface NokPresentActions : NSObject
@end
@implementation NokPresentActions
- (void)toggleFill:(id)sender { setFilling(!filling); }
- (BOOL)validateMenuItem:(NSMenuItem *)item { item.title = filling ? @"Exit Full Screen" : @"Enter Full Screen"; return frameWindow != nil; }
@end
static NokPresentActions *actions;

static void addMenuItem(void) {
    NSMenu *main = NSApp.mainMenu;
    NSMenuItem *window = nil;
    for (NSMenuItem *i in main.itemArray) if ([i.submenu.title isEqualToString:@"Window"] || [i.title isEqualToString:@"Window"]) window = i;
    NSMenu *m = window.submenu;
    if (!m) return;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen" action:@selector(toggleFill:) keyEquivalent:@"f"];
    item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    item.target = actions;
    [m insertItem:item atIndex:0];
    [m insertItem:NSMenuItem.separatorItem atIndex:1];
}

// MARK: Resizing from inside the edges
// The window server resizes windows from their outer edge, but there the game's own (full-size, transformed)
// window sits on top, so the frame never sees it. A thin band just inside the picture's edge resizes instead.
static const CGFloat band = 5;     // the window's outermost points: resize there (macOS's own zone sits outside)
static CGRect frameRectTL(void) { return toTopLeft(frameWindow.frame); }
static BOOL inResizeBand(CGPoint p) {
    if (!frameWindow || filling || (frameWindow.styleMask & NSWindowStyleMaskFullScreen)) return NO;
    CGRect f = frameRectTL();
    return CGRectContainsPoint(f, p) && !CGRectContainsPoint(CGRectInset(f, band, band), p);
}

/// Which edges a point is on, as NSCursor frame-resize directions.
static void edgesAt(CGPoint p, BOOL *l, BOOL *r, BOOL *t, BOOL *b) {
    CGRect d = frameRectTL(); CGFloat k = 18;          // corners are generous
    *l = p.x < CGRectGetMinX(d) + band; *r = p.x > CGRectGetMaxX(d) - band;
    *t = p.y < CGRectGetMinY(d) + band; *b = p.y > CGRectGetMaxY(d) - band;
    if (*l || *r) { *t = *t || p.y < CGRectGetMinY(d) + k; *b = *b || p.y > CGRectGetMaxY(d) - k; }
    if (*t || *b) { *l = *l || p.x < CGRectGetMinX(d) + k; *r = *r || p.x > CGRectGetMaxX(d) - k; }
}

static void showResizeCursor(CGPoint p) {
    BOOL l, r, t, b; edgesAt(p, &l, &r, &t, &b);
    NSCursor *c = nil;
    if (@available(macOS 15.0, *)) {
        NSCursorFrameResizePosition pos = 0;
        if (t) pos |= NSCursorFrameResizePositionTop;
        if (b) pos |= NSCursorFrameResizePositionBottom;
        if (l) pos |= NSCursorFrameResizePositionLeft;
        if (r) pos |= NSCursorFrameResizePositionRight;
        if (pos) c = [NSCursor frameResizeCursorFromPosition:pos inDirections:NSCursorFrameResizeDirectionsAll];
    }
    if (!c) c = (l || r) && !(t || b) ? NSCursor.resizeLeftRightCursor : (t || b) && !(l || r) ? NSCursor.resizeUpDownCursor : NSCursor.crosshairCursor;
    [c set];
}
static void trackResize(NSEvent *down) {
    CGPoint start = CGEventGetLocation(down.CGEvent);
    NSRect f0 = frameWindow.frame, c0 = [frameWindow contentRectForFrameRect:f0];
    BOOL left, right, top, bottom; edgesAt(start, &left, &right, &top, &bottom);
    NSSize aspect = gameWindow ? gameWindow.frame.size : c0.size;
    while (true) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                        untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
        showResizeCursor(start);
        CGPoint p = CGEventGetLocation(e.CGEvent);
        CGFloat dx = p.x - start.x, dy = p.y - start.y;      // top-left space: +y is down
        CGFloat w = c0.size.width + (right ? dx : left ? -dx : 0);
        CGFloat h = c0.size.height + (bottom ? dy : top ? -dy : 0);
        // Keep the game's shape: follow whichever edge moved more.
        if ((left || right) && (!(top || bottom) || fabs(dx) >= fabs(dy))) h = w * aspect.height / aspect.width;
        else w = h * aspect.width / aspect.height;
        w = MAX(w, aspect.width / 8); h = MAX(h, aspect.height / 8);
        NSRect c = c0;                                       // Cocoa: origin is bottom-left
        c.size = NSMakeSize(w, h);
        if (left) c.origin.x = NSMaxX(c0) - w;
        if (!bottom) c.origin.y = c0.origin.y;               // top edge moves: keep the bottom
        if (bottom) c.origin.y = NSMaxY(c0) - h;             // bottom edge moves: keep the top
        [frameWindow setFrame:[frameWindow frameRectForContentRect:c] display:YES];
        updateGeometry();
        if (e.type == NSEventTypeLeftMouseUp) break;
    }
}

static void adoptGameWindow(NSWindow *g) {
    gameWindow = g;
    NSSize gs = g.frame.size;
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    // First size: about three quarters of the screen, the game's shape (older games' small resolutions grow).
    CGFloat fit = MIN(screen.size.width * 0.75 / gs.width, screen.size.height * 0.75 / gs.height);
    NSSize size = firstSize.width > 0 ? firstSize : NSMakeSize(round(gs.width * fit), round(gs.height * fit));
    NSRect content = NSMakeRect(NSMidX(screen) - size.width / 2, NSMidY(screen) - size.height / 2, size.width, size.height);
    frameWindow = [[NokPresentFrame alloc] initWithContentRect:content
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    frameWindow.releasedWhenClosed = NO;
    frameWindow.title = NSProcessInfo.processInfo.processName;
    // The frame is the top window: its content is see-through and the game's picture shows from just
    // below it. Being on top, the frame gets macOS's own edge resizing and its title bar is never covered.
    frameWindow.opaque = NO;
    frameWindow.backgroundColor = NSColor.clearColor;
    frameWindow.ignoresMouseEvents = NO;              // transparent, but still takes every click
    frameWindow.contentView = [[NokPresentContent alloc] initWithFrame:NSMakeRect(0, 0, content.size.width, content.size.height)];
    frameWindow.contentAspectRatio = gs;              // the window keeps the game's shape (full screen may letterbox)
    // Content = picture + padding on each side (no letterboxing in this first step).
    content.size.width += 2 * padding(); content.size.height += 2 * padding();
    [frameWindow setContentSize:content.size];
    frameWindow.contentMinSize = NSMakeSize(gs.width / 8, gs.height / 8);
    frameWindow.acceptsMouseMovedEvents = YES;
    frameWindow.collectionBehavior = NSWindowCollectionBehaviorManaged |
        (nativeFS() ? NSWindowCollectionBehaviorFullScreenPrimary : NSWindowCollectionBehaviorFullScreenNone);
    delegate = [NokPresentDelegate new];
    frameWindow.delegate = delegate;
    frameWindow.level = NSNormalWindowLevel;
    g.level = NSNormalWindowLevel;
    [frameWindow orderFront:nil];
    tieToFrame();
    solidTitlebar();
    actions = [NokPresentActions new];
    NSButton *zoom = [frameWindow standardWindowButton:NSWindowZoomButton];
    if (!nativeFS()) { zoom.target = actions; zoom.action = @selector(toggleFill:); }
    addMenuItem();
    updateGeometry();
    [NSApp activateIgnoringOtherApps:YES];
    selfTest();
    note(@"presenting window %ld (%@) in frame %@", (long)g.windowNumber, NSStringFromSize(gs), NSStringFromRect(content));
}

static void scan(void) {
    if (!enabled) return;
    NSWindow *g = gameWindow;
    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    if (virtW > 0) screen.size = CGSizeMake(virtW, virtH);     // the game's screen
    if (!g || !g.isVisible) {
        for (NSWindow *w in NSApp.windows) {
            if (!isWineWindow(w) || !w.isVisible) continue;
            if (w.frame.size.width >= screen.size.width * 0.9 && w.frame.size.height >= screen.size.height * 0.9) {
                if (!frameWindow) adoptGameWindow(w);
                else { gameWindow = w; updateGeometry(); }
                break;
            }
        }
        return;
    }
    // Keep the frame just below the game in the window order, and follow Wine's window moves.
    // A game in a window behaves like any app's window: other windows can come in front of it. (Fullscreen
    // games ask Wine for "topmost", which would keep it above everything.)
    BOOL fs = (frameWindow.styleMask & NSWindowStyleMaskFullScreen) != 0;
    NSWindowLevel want = NSNormalWindowLevel; (void)fs;
    if (!fs && frameWindow.level != NSNormalWindowLevel) frameWindow.level = NSNormalWindowLevel;
    if (g.level != want) g.level = want;
    if (fs) raiseTitlebar();
    updateGeometry();
    updateCapture();
    // Diagnostics: a line whenever the state that decides where the mouse goes changes.
    static NSString *lastState;
    id ctl = [objc_getClass("WineApplicationController") performSelector:@selector(sharedController)];
    id capture = nil; NSUInteger dragged = 0;
    @try { capture = [ctl valueForKey:@"mouseCaptureWindow"]; dragged = [[ctl valueForKey:@"windowsBeingDragged"] count]; } @catch (id x) {}
    NSString *st = [NSString stringWithFormat:@"state: game %ld %@ key %d visible %d | key window %@ | active %d | capture %@ dragged %lu | confining %d clip %@ manual %d | wine windows %lu",
        (long)g.windowNumber, NSStringFromRect(g.frame), g.isKeyWindow, g.isVisible, NSApp.keyWindow.class, NSApp.isActive,
        capture ? @"yes" : @"no", (unsigned long)dragged, confining, NSStringFromRect(NSRectFromCGRect(gameClip)), manualCapture,
        (unsigned long)[NSApp.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSWindow *w, id b) { return isWineWindow(w) && w.isVisible; }]].count];
    if (![st isEqualToString:lastState]) { note(@"%@", st); lastState = st; }
}

// MARK: Self-test (NOKCANDU_PRESENT_SELFTEST=1|fullscreen)
// Sends clicks at the picture's corners and centre through the same path as real clicks on the frame, at
// several window sizes (and in full screen), so alignment can be checked from the game's own log.
static void clickAt(CGPoint screenTopLeft) {
    NSWindow *f = frameWindow; if (!f) return;
    NSPoint cocoa = NSMakePoint(screenTopLeft.x, primaryHeight() - screenTopLeft.y);
    NSPoint local = [f convertPointFromScreen:cocoa];
    NSEventType types[2] = {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp};
    for (int i = 0; i < 2; i++) {
        NSEvent *e = [NSEvent mouseEventWithType:types[i] location:local modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:f.windowNumber context:nil eventNumber:0 clickCount:1 pressure:i == 0 ? 1 : 0];
        [NSApp sendEvent:e];
    }
}
static void clickCorners(NSString *label) {
    CGRect d = geo.display; CGFloat k = 12 * geo.scale + 2;
    note(@"selftest %@: picture %@ scale %.3f", label, NSStringFromRect(NSRectFromCGRect(d)), geo.scale);
    CGPoint pts[5] = { {CGRectGetMinX(d) + k, CGRectGetMinY(d) + k}, {CGRectGetMaxX(d) - k, CGRectGetMinY(d) + k},
                       {CGRectGetMinX(d) + k, CGRectGetMaxY(d) - k}, {CGRectGetMaxX(d) - k, CGRectGetMaxY(d) - k},
                       {CGRectGetMidX(d), CGRectGetMidY(d)} };
    for (int i = 0; i < 5; i++) clickAt(pts[i]);
}
static void after(double s, void (^b)(void)) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), b); }
static void selfTest(void) {
    const char *mode = getenv("NOKCANDU_PRESENT_SELFTEST");
    if (!mode) return;
    after(1.5, ^{ clickCorners(@"start"); });
    if (strcmp(mode, "modes") == 0) {
        for (int k = 0; k < 2; k++) {
            after(2.5 + k * 3, ^{ NSWindow *g = gameWindow;
                NSEvent *d = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:g.windowNumber context:nil characters:@"m" charactersIgnoringModifiers:@"m" isARepeat:NO keyCode:46];
                NSEvent *u = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:g.windowNumber context:nil characters:@"m" charactersIgnoringModifiers:@"m" isARepeat:NO keyCode:46];
                [NSApp sendEvent:d]; [NSApp sendEvent:u]; note(@"selftest: pressed M"); });
            after(4.5 + k * 3, ^{ note(@"after mode change: game window %@ real screen %@", NSStringFromRect(gameWindow.frame), NSStringFromRect(CGDisplayBounds(CGMainDisplayID())));
                                  clickCorners([NSString stringWithFormat:@"mode %d", k]); });
        }
        return;
    }
    after(3, ^{ NSRect f = frameWindow.frame; f.size.width *= 1.3; f.size.height = (f.size.height - 28) * 1.3 + 28;
                [frameWindow setFrame:f display:YES]; updateGeometry(); });
    after(4, ^{ clickCorners(@"larger"); });
    after(5, ^{ [frameWindow setFrame:NSMakeRect(40, 60, 500, 340) display:YES]; updateGeometry(); });
    after(6, ^{ clickCorners(@"small, different shape"); });
    if (strcmp(mode, "move") == 0) {
        after(2, ^{ note(@"before move: game %@", NSStringFromRect(gameWindow.frame));
                    NSRect f = frameWindow.frame; f.origin.x += 120; f.origin.y -= 80; [frameWindow setFrame:f display:YES]; });
        after(3, ^{ note(@"after move: game %@", NSStringFromRect(gameWindow.frame)); clickCorners(@"moved"); });
        return;
    }
    if (strcmp(mode, "track") == 0) {
        // Moves across the picture in 20 steps, at two window sizes: the game's raw-input total should match the
        // distance in game pixels, and its cursor should end where the pointer is.
        for (int k = 0; k < 2; k++) {
            if (k == 1) after(5, ^{ [frameWindow setFrame:NSMakeRect(100, 100, 900, 700) display:YES]; updateGeometry(); note(@"selftest: resized"); });
            for (int i = 0; i <= 20; i++) after(2 + k * 4 + i * 0.05, ^{
                CGRect d = geo.display; NSWindow *f = frameWindow;
                CGPoint p = CGPointMake(CGRectGetMinX(d) + 5 + (d.size.width - 10) * i / 20.0, CGRectGetMidY(d));
                NSPoint local = [f convertPointFromScreen:NSMakePoint(p.x, primaryHeight() - p.y)];
                NSEvent *m = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:local modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                             windowNumber:f.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
                [NSApp sendEvent:m];
                if (i == 20) { note(@"selftest track %d: picture %@ game %@", k, NSStringFromRect(NSRectFromCGRect(d)), NSStringFromRect(NSRectFromCGRect(geo.game))); clickAt(p); }
            });
        }
        return;
    }
    if (strcmp(mode, "aim") == 0) {
        after(2, ^{ NSWindow *g = gameWindow;
            NSEvent *d = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:g.windowNumber context:nil characters:@"h" charactersIgnoringModifiers:@"h" isARepeat:NO keyCode:4];
            NSEvent *u = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:g.windowNumber context:nil characters:@"h" charactersIgnoringModifiers:@"h" isARepeat:NO keyCode:4];
            [NSApp sendEvent:d]; [NSApp sendEvent:u]; note(@"selftest: pressed H"); });
        for (int i = 0; i < 6; i++) after(3 + i * 0.3, ^{
            CGRect d = geo.display; NSWindow *f = frameWindow;
            CGPoint p = CGPointMake(CGRectGetMinX(d) + 40 + i * 30, CGRectGetMinY(d) + 40 + i * 20);
            NSPoint local = [f convertPointFromScreen:NSMakePoint(p.x, primaryHeight() - p.y)];
            NSEvent *m = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:local modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                         windowNumber:f.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
            [NSApp sendEvent:m]; });
        return;
    }
    if (strcmp(mode, "fullscreen") == 0) {
        after(7, ^{ setFilling(YES); });
        after(10, ^{ NSWindow *g = gameWindow;
                     note(@"in full screen: frame %@ game %@ key %@ onActiveSpace %d", NSStringFromRect(frameWindow.frame), NSStringFromRect(g.frame),
                          NSApp.keyWindow, g.isOnActiveSpace);
                     clickCorners(@"full screen"); });
        after(11, ^{ setFilling(NO); });
        after(14, ^{ note(@"after full screen: frame %@ game %@ key %@ order frame %ld game %ld style %lx", NSStringFromRect(frameWindow.frame), NSStringFromRect(gameWindow.frame), NSApp.keyWindow,
                          (long)frameWindow.orderedIndex, (long)gameWindow.orderedIndex, (unsigned long)frameWindow.styleMask);
                     clickCorners(@"after full screen"); });
        after(15, ^{ for (NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"]) [a activateWithOptions:0]; });
        after(17, ^{ NSWindow *g = gameWindow;
                     note(@"deactivated: game visible %d occlusion %lu alpha %.2f order %ld level %ld frame %@ / frame window order %ld visible %d",
                          g.isVisible, (unsigned long)g.occlusionState, g.alphaValue, (long)g.orderedIndex, (long)g.level, NSStringFromRect(g.frame),
                          (long)frameWindow.orderedIndex, frameWindow.isVisible); });
    }
}

// MARK: Input

/// A mouse event over the frame's content becomes the same event at the matching point of the game.
static NSEvent *rewrite(NSEvent *e) {
    if (!frameWindow || !gameWindow || !geo.valid) return e;
    switch (e.type) {
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp: case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: case NSEventTypeOtherMouseDragged: case NSEventTypeScrollWheel: break;
        default: return e;
    }
    CGEventRef cg = e.CGEvent;
    if (!cg) return e;
    CGPoint p = CGEventGetLocation(cg);                     // global, top-left origin
    // macOS's own windows (the title bar it slides down in full screen, menus) keep their events.
    if (e.window && e.window != frameWindow && !isWineWindow(e.window)) return e;
    // In full screen the very top edge reveals the title bar and menu bar: leave it to macOS.
    if (filling && p.y < CGDisplayBounds(CGMainDisplayID()).origin.y + 3) return e;
    BOOL inside = CGRectContainsPoint(geo.display, p);
    // Clicks on the title bar or resize edges stay with the frame; everything over the picture goes to the game.
    if (!inside && e.type != NSEventTypeLeftMouseDragged && e.type != NSEventTypeLeftMouseUp && e.type != NSEventTypeMouseMoved) return e;
    if (!inside && e.window == frameWindow) return e;       // dragging the frame itself
    CGPoint gp = nok_present_to_game(&geo, p);
    NSWindow *target = gameWindow;
    if (e.type == NSEventTypeScrollWheel) {
        // Scroll events can't be re-addressed through NSEvent; move the copy's location (Wine reads it).
        CGEventRef copy = CGEventCreateCopy(cg);
        CGEventSetLocation(copy, gp);
        NSEvent *n = [NSEvent eventWithCGEvent:copy];
        CFRelease(copy);
        return n ?: e;
    }
    // Rebuild the event addressed to the game's window, at the matching point (in that window's own
    // bottom-left coordinates). Wine reads the window and the event's screen location from it.
    CGRect gw = geo.game;                               // the game window, in Windows coordinates
    NSPoint local = NSMakePoint(gp.x - gw.origin.x, CGRectGetMaxY(gw) - gp.y);
    NSEvent *n = [NSEvent mouseEventWithType:e.type location:local modifierFlags:e.modifierFlags timestamp:e.timestamp
                                windowNumber:target.windowNumber context:nil eventNumber:e.eventNumber
                                  clickCount:(e.type == NSEventTypeMouseMoved ? 0 : e.clickCount)
                                    pressure:(e.type == NSEventTypeMouseMoved ? 0 : e.pressure)];
    if (n && e.type != NSEventTypeMouseMoved && e.type != NSEventTypeLeftMouseDown && e.type != NSEventTypeLeftMouseUp &&
        e.type != NSEventTypeLeftMouseDragged && e.type != NSEventTypeRightMouseDown && e.type != NSEventTypeRightMouseUp &&
        e.type != NSEventTypeRightMouseDragged) {
        // Other (middle, side) buttons keep their button number.
        CGEventRef c = CGEventCreateCopy(n.CGEvent);
        CGEventSetIntegerValueField(c, kCGMouseEventButtonNumber, e.buttonNumber);
        n = [NSEvent eventWithCGEvent:c] ?: n;
        CFRelease(c);
    }
    // Wine reads the event's screen location as Windows coordinates; with a virtual display those differ from
    // where AppKit put it.
    if (n && virtW > 0) {
        CGEventRef c = CGEventCreateCopy(n.CGEvent);
        CGEventSetLocation(c, gp);
        NSEvent *m = [NSEvent eventWithCGEvent:c];
        CFRelease(c);
        if (m.windowNumber == target.windowNumber) n = m;
        else note(@"virtual display: re-addressed event lost its window");
    }
    return n ?: e;
}

// Wine raises "topmost"/fullscreen windows to high levels (and changes them on activation). A presented game
// is an ordinary window: keep it at the normal level, under its frame.
static void (*orig_setLevel)(id, SEL, NSWindowLevel);
static void my_setLevel(NSWindow *self, SEL _cmd, NSWindowLevel level) {
    if (enabled && self == gameWindow && frameWindow) level = NSNormalWindowLevel;
    orig_setLevel(self, _cmd, level);
}

// Wine re-orders its windows (activation, its own z-order); the game's window must stay right below its frame.
static void my_orderRelative(NSWindow *self, SEL _cmd, NSWindowOrderingMode mode, NSInteger other) {
    orig_orderRelative(self, _cmd, mode, other);
    if (enabled && self == gameWindow && frameWindow && mode != NSWindowOut && !(mode == NSWindowBelow && other == frameWindow.windowNumber))
        orig_orderRelative(self, _cmd, NSWindowBelow, frameWindow.windowNumber);
}

// A fullscreen game that hides the pointer (aiming, camera control) expects it can't leave its screen. In a
// window it could: while the game hides the pointer and is in front, the pointer is kept inside the picture.
static ptrdiff_t hiddenIvar = -1;
static BOOL gameHidesCursor(void) {
    id ctl = [objc_getClass("WineApplicationController") performSelector:@selector(sharedController)];
    if (!ctl) return NO;
    if (hiddenIvar < 0) { Ivar iv = class_getInstanceVariable(object_getClass(ctl), "clientWantsCursorHidden"); hiddenIvar = iv ? ivar_getOffset(iv) : 0; }
    return hiddenIvar > 0 && *((BOOL *)((__bridge void *)ctl + hiddenIvar));
}
static double lastGameWarp;         // when the game last moved the pointer itself (aiming re-centres every frame)
/// Aiming: the game hides the pointer and keeps moving it back (FPS cameras). Then, like in real full screen,
/// the pointer can't wander out of the picture. Games that only hide the Mac pointer to draw their own (most
/// strategy games) are left free, so you can move out to other apps or the window's edges.
static void updateCapture(void) {
    NSWindow *g = gameWindow;
    if (!g || !geo.valid) return;
    if (!NSApp.isActive) manualCapture = NO;           // switching away (Command-Tab) always lets go
    BOOL want = NSApp.isActive && g.isKeyWindow &&
        (manualCapture || !CGRectIsEmpty(gameClip) || (gameHidesCursor() && CFAbsoluteTimeGetCurrent() - lastGameWarp < 0.5));
    if (want != confining) note(want ? @"pointer kept in the picture (aiming)" : @"pointer released");
    confining = want;
}
/// While aiming, a pointer that leaves the picture is put back at its edge.
static BOOL keepInside(CGPoint p) {
    if (!confining) return NO;
    CGRect area = geo.display;
    if (!CGRectIsEmpty(gameClip) && !manualCapture) {
        CGPoint a = nok_present_to_screen(&geo, gameClip.origin), b = nok_present_to_screen(&geo, CGPointMake(CGRectGetMaxX(gameClip), CGRectGetMaxY(gameClip)));
        area = CGRectIntersection(CGRectMake(a.x, a.y, b.x - a.x, b.y - a.y), geo.display);
    }
    CGRect d = CGRectInset(area, 1, 1);
    if (CGRectContainsPoint(d, p)) return NO;
    CGPoint q = CGPointMake(MIN(MAX(p.x, CGRectGetMinX(d)), CGRectGetMaxX(d)), MIN(MAX(p.y, CGRectGetMinY(d)), CGRectGetMaxY(d)));
    CGWarpMouseCursorPosition(q);
    return YES;
}

// ClipCursor: Wine asks macOS to confine the pointer to a rect relative to the game's (unscaled, hidden) window,
// which would trap it in a region of the screen that isn't the picture. Keep the request here instead and keep
// the pointer inside the matching part of the picture while the game is in front.
static void (*orig_setConfinement)(id, SEL, NSRect);
static void my_setConfinement(NSWindow *self, SEL _cmd, NSRect r) {
    if (!enabled || !frameWindow || !isWineWindow(self)) { orig_setConfinement(self, _cmd, r); return; }
    if (NSIsEmptyRect(r)) gameClip = CGRectNull;
    else {
        CGRect w = toWin(self.frame);          // the window in the game's coordinates
        gameClip = CGRectMake(w.origin.x + r.origin.x, w.origin.y + w.size.height - NSMaxY(r), r.size.width, r.size.height);
    }
    note(@"game clip %@", NSStringFromRect(NSRectFromCGRect(gameClip)));
    updateCapture();
}

// Wine finds the window under the pointer itself (for plain mouse moves). Over the picture, that's the game.
static NSInteger (*orig_numberAtPoint)(id, SEL, NSPoint, NSInteger);
static BOOL handlingGameEvent;
static BOOL isMouseEvent(NSEvent *e) {
    switch (e.type) {
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp: case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: case NSEventTypeOtherMouseDragged:
        case NSEventTypeScrollWheel: case NSEventTypeMouseEntered: case NSEventTypeMouseExited: case NSEventTypeCursorUpdate: return YES;
        default: return NO;
    }
}     // true while Wine handles an event this library re-addressed to the game
static NSInteger my_numberAtPoint(id self, SEL _cmd, NSPoint p, NSInteger below) {
    NSWindow *g = gameWindow;
    // Only for events over the picture: elsewhere (the title bar, the frame's edges, other apps) the pointer
    // isn't over the game, so Wine leaves the pointer's shape to macOS (resize arrows at the edges).
    if (enabled && geo.valid && g && handlingGameEvent && NSPointInRect(p, g.frame)) return g.windowNumber;
    return orig_numberAtPoint(self, _cmd, p, below);
}

static void (*orig_sendEvent)(id, SEL, NSEvent *);
static void my_sendEvent(id self, SEL _cmd, NSEvent *e) {
    if (confining && e.CGEvent && (e.type == NSEventTypeMouseMoved || e.type == NSEventTypeLeftMouseDragged || e.type == NSEventTypeRightMouseDragged)
        && keepInside(CGEventGetLocation(e.CGEvent))) return;
    if (frameWindow && e.CGEvent && (e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeMouseMoved)
        && inResizeBand(CGEventGetLocation(e.CGEvent))) {
        showResizeCursor(CGEventGetLocation(e.CGEvent));
        if (e.type == NSEventTypeLeftMouseDown) trackResize(e);
        return;
    }
    // Control-Command-Escape: capture the pointer in the picture (again: let go).
    if (frameWindow && e.type == NSEventTypeKeyDown && e.keyCode == 53 &&
        (e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == (NSEventModifierFlagControl | NSEventModifierFlagCommand)) {
        manualCapture = !manualCapture; updateCapture();
        note(@"pointer capture %@ (Control-Command-Escape)", manualCapture ? @"on" : @"off");
        return;
    }
    // Shift-Command-Escape lets go (Escape alone always belongs to the game).
    if (frameWindow && e.type == NSEventTypeKeyDown && e.keyCode == 53 &&
        (e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == (NSEventModifierFlagShift | NSEventModifierFlagCommand)) {
        manualCapture = NO; updateCapture(); note(@"pointer capture off (Shift-Command-Escape)");
        return;
    }
    // Control-Command-F: full screen (see setFilling).
    if (frameWindow && e.type == NSEventTypeKeyDown && [e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"f"] &&
        (e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == (NSEventModifierFlagControl | NSEventModifierFlagCommand)) {
        setFilling(!filling);
        return;
    }
    NSEvent *r = rewrite(e);
    handlingGameEvent = (r != e);
    if (r == e && frameWindow && e.window == frameWindow && isMouseEvent(e)) {
        // The frame's own title bar and edges: plain AppKit handling. Wine would otherwise treat the pointer
        // as leaving its windows and reset the pointer's shape (the resize arrows flickered).
        static void (*appSend)(id, SEL, NSEvent *);
        if (!appSend) appSend = (void *)class_getMethodImplementation([NSApplication class], @selector(sendEvent:));
        appSend(self, _cmd, e);
    } else orig_sendEvent(self, _cmd, r);
    handlingGameEvent = NO;
    // Wine brings its window forward on clicks; keep the frame on top of it.
    NSWindow *g = gameWindow;
    if (g && frameWindow && e.type == NSEventTypeLeftMouseDown && frameWindow.orderedIndex > g.orderedIndex)
        tieToFrame();
}

// GetCursorPos and friends read +[NSEvent mouseLocation] (Cocoa coordinates).
static NSPoint (*orig_mouseLocation)(id, SEL);
static NSPoint my_mouseLocation(id self, SEL _cmd) {
    NSPoint p = orig_mouseLocation(self, _cmd);
    if (!enabled || !geo.valid || !fromWine(__builtin_return_address(0))) return p;
    CGPoint g = nok_present_to_game(&geo, CGPointMake(p.x, primaryHeight() - p.y));
    return NSMakePoint(g.x, wineHeight() - g.y);
}

// The game moving the cursor (aiming re-centres it, menus place it) lands at the matching point in the frame.
static CGError my_warp(CGPoint p) {
    lastGameWarp = CFAbsoluteTimeGetCurrent();     // the game (through Wine) moved the pointer
    if (enabled && geo.valid) p = nok_present_to_screen(&geo, p);
    return CGWarpMouseCursorPosition(p);
}
/// For the raw-mouse code in the same library (interposing doesn't reach calls inside this library): a point
/// on the game window's real, unscaled frame -> where it shows on screen.
void nok_present_warp_real(CGPoint p) {
    NSWindow *g = gameWindow;
    if (enabled && geo.valid && g) {
        CGRect real = toTopLeft(g.frame);
        p = nok_present_to_screen(&geo, CGPointMake(geo.game.origin.x + p.x - real.origin.x, geo.game.origin.y + p.y - real.origin.y));
    }
    CGWarpMouseCursorPosition(p);
}
__attribute__((used)) static const struct { const void *replacement, *original; } warp_interpose[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)my_warp, (const void *)CGWarpMouseCursorPosition } };

static void hook(Class c, SEL s, IMP mine, IMP *orig, BOOL meta) {
    Method m = meta ? class_getClassMethod(c, s) : class_getInstanceMethod(c, s);
    if (m) *orig = method_setImplementation(m, mine);
}

/// The game's setting, next to this library (SharedSupport/nokcandu/windowed): "on" plus an optional line with
/// the game's resolution ("1280x720"). The environment (NOKCANDU_PRESENT=1, NOKCANDU_PRESENT_RESOLUTION) is
/// for testing.
static BOOL readSetting(void) {
    const char *on = getenv("NOKCANDU_PRESENT");
    if (on) return strcmp(on, "1") == 0;
    Dl_info self;
    if (!dladdr((const void *)readSetting, &self) || !self.dli_fname) return NO;
    NSString *dir = [[NSString stringWithUTF8String:self.dli_fname] stringByDeletingLastPathComponent];
    NSString *t = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"windowed"] encoding:NSUTF8StringEncoding error:nil];
    if (!t) return NO;
    BOOL enabledHere = NO;
    for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        int w, h;
        if ([l isEqualToString:@"on"]) enabledHere = YES;
        else if (sscanf(l.UTF8String, "%dx%d", &w, &h) == 2 && !getenv("NOKCANDU_PRESENT_RESOLUTION"))
            setenv("NOKCANDU_PRESENT_RESOLUTION", l.UTF8String, 1);
    }
    return enabledHere;
}

__attribute__((constructor)) static void start(void) {
    if (!readSetting()) return;
    int w = 0, h = 0; const char *sz = getenv("NOKCANDU_PRESENT_SIZE");
    if (sz && sscanf(sz, "%dx%d", &w, &h) == 2 && w > 100 && h > 100) firstSize = NSMakeSize(w, h);
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    SLSSetWindowTransform = sl ? dlsym(sl, "SLSSetWindowTransform") : NULL;
    SLSMainConnectionID = sl ? dlsym(sl, "SLSMainConnectionID") : NULL;
    SLSAddWindowToWindowOrderingGroup = sl ? dlsym(sl, "SLSAddWindowToWindowOrderingGroup") : NULL;
    SLSRemoveFromOrderingGroup = sl ? dlsym(sl, "SLSRemoveFromOrderingGroup") : NULL;
    if (!SLSSetWindowTransform || !SLSMainConnectionID) { note(@"window transforms unavailable on this macOS; staying off"); return; }
    // The virtual display has to exist before Wine first looks at the screen.
    enabled = YES;
    hook([NSScreen class], @selector(frame), (IMP)my_screenFrame, (IMP *)&orig_screenFrame, NO);
    hook([NSScreen class], @selector(visibleFrame), (IMP)my_screenVisible, (IMP *)&orig_screenVisible, NO);
    hook([NSScreen class], @selector(screens), (IMP)my_screens, (IMP *)&orig_screens, YES);
    int rw = 0, rh = 0; const char *res = getenv("NOKCANDU_PRESENT_RESOLUTION");
    if (readSharedMode(&rw, &rh) || (res && sscanf(res, "%dx%d", &rw, &rh) == 2)) {
        CGRect real = CGDisplayBounds(CGMainDisplayID());
        CGDisplayModeRef m = (rw == real.size.width && rh == real.size.height) ? NULL : carrierFor(rw, rh);
        if (m || rw == real.size.width) setVirtualMode(m); else note(@"no mode for %dx%d", rw, rh);
    }
    // Wine's Mac driver loads after this library: wait for its application class on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            Class app = objc_getClass("WineApplication");
            if (!app || !NSApp) return;
            [t invalidate];
            enabled = YES;
            hook(app, @selector(sendEvent:), (IMP)my_sendEvent, (IMP *)&orig_sendEvent, NO);
            hook([NSEvent class], @selector(mouseLocation), (IMP)my_mouseLocation, (IMP *)&orig_mouseLocation, YES);
            hook([NSWindow class], @selector(windowNumberAtPoint:belowWindowWithWindowNumber:), (IMP)my_numberAtPoint, (IMP *)&orig_numberAtPoint, YES);
            Class ctl = objc_getClass("WineApplicationController");
            if (ctl) hook(ctl, NSSelectorFromString(@"setMode:forDisplay:"), (IMP)my_setModeForDisplay, (IMP *)&orig_setModeForDisplay, NO);
            Class ww = objc_getClass("WineWindow");
            if (ww) hook(ww, @selector(setLevel:), (IMP)my_setLevel, (IMP *)&orig_setLevel, NO);
            if (ww) hook(ww, @selector(orderWindow:relativeTo:), (IMP)my_orderRelative, (IMP *)&orig_orderRelative, NO);
            SEL conf = NSSelectorFromString(@"setMouseConfinementRect:");
            if ([NSWindow instancesRespondToSelector:conf]) hook([NSWindow class], conf, (IMP)my_setConfinement, (IMP *)&orig_setConfinement, NO);
            [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t2) {
                // Another process of the game changed the display mode.
                int fw, fh;
                if (readSharedMode(&fw, &fh)) {
                    CGRect real = CGDisplayBounds(CGMainDisplayID());
                    CGFloat cw = virtW > 0 ? virtW : real.size.width, ch = virtW > 0 ? virtH : real.size.height;
                    if (fw != cw || fh != ch) {
                        setVirtualMode((fw == real.size.width && fh == real.size.height) ? NULL : carrierFor(fw, fh));
                        displaysChanged();
                    }
                }
                scan();
            }];
            for (NSString *n in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification])
                [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note_) { tieToFrame(); }];
            note(@"presentation ready");
        }];
    });
}
