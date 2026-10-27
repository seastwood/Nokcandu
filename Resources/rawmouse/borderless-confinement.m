// Wine's native confinement rectangle can remain tied to the old window geometry after a
// borderless resize. Re-submit Wine's existing request only when its projected bounds differ
// from the Mac window's actual confinement. Never invent a clip rectangle or move the cursor.
@interface NSObject (NokcanduConfinement)
+ (NSRect)rectForScreenRect:(CGRect)rect inWindow:(NSWindow *)window;
- (BOOL)startClippingCursor:(CGRect)rect;
@end
@interface NSWindow (NokcanduConfinement)
- (NSRect)mouseConfinementRect;
@end
static char borderless_confinement_record[PATH_MAX];
static BOOL confinement_rect_close(NSRect a, NSRect b) {
    return fabs(a.origin.x-b.origin.x)<0.5 && fabs(a.origin.y-b.origin.y)<0.5 &&
        fabs(a.size.width-b.size.width)<0.5 && fabs(a.size.height-b.size.height)<0.5;
}
static void install_borderless_confinement(void) {
    if (!borderless_confinement_record[0] || access(borderless_confinement_record, F_OK) != 0) return;
    Class kind = objc_getClass("WineConfinementClipCursorHandler");
    if (!kind || ![NSWindow instancesRespondToSelector:@selector(mouseConfinementRect)]) return;
    NSMethodSignature *projection = [kind methodSignatureForSelector:@selector(rectForScreenRect:inWindow:)];
    NSMethodSignature *start = [kind instanceMethodSignatureForSelector:@selector(startClippingCursor:)];
    if (!projection || projection.numberOfArguments != 4 || projection.methodReturnLength != sizeof(NSRect) ||
        strcmp([projection getArgumentTypeAtIndex:2], @encode(CGRect)) ||
        [projection getArgumentTypeAtIndex:3][0] != '@' || strcmp(projection.methodReturnType, @encode(NSRect)) ||
        !start || start.numberOfArguments != 3 || strcmp([start getArgumentTypeAtIndex:2], @encode(CGRect)) ||
        strcmp(start.methodReturnType, @encode(BOOL))) {
        note(@"borderless mouse bounds: unsupported Wine layout; left unchanged"); return;
    }
    __block BOOL attempted = NO;
    __block NSInteger lastWindow = 0;
    __block NSRect lastActual = NSZeroRect, lastExpected = NSZeroRect, lastFrame = NSZeroRect;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(__unused NSTimer *timer) {
        if (!NSApp.isActive || access(borderless_confinement_record, F_OK) != 0) { attempted = NO; return; }
        NSWindow *window = NSApp.keyWindow;
        if (![window isKindOfClass:objc_getClass("WineWindow")] || !window.isVisible || window.isMiniaturized) { attempted = NO; return; }
        @try {
            id handler = [controller() valueForKey:@"clipCursorHandler"];
            if (![handler isKindOfClass:kind] || ![[handler valueForKey:@"clippingCursor"] boolValue]) { attempted = NO; return; }
            NSNumber *owner = [handler valueForKey:@"clippingWindowNumber"];
            if (![owner isKindOfClass:NSNumber.class] || owner.integerValue != window.windowNumber) return;
            NSValue *value = [handler valueForKey:@"cursorClipRect"];
            if (![value isKindOfClass:NSValue.class] || strcmp(value.objCType, @encode(CGRect))) return;
            CGRect requested = value.rectValue;
            if (!isfinite(requested.origin.x) || !isfinite(requested.origin.y) ||
                !isfinite(requested.size.width) || !isfinite(requested.size.height) ||
                requested.size.width <= 0 || requested.size.height <= 0) return;
            NSRect expected = [(id)kind rectForScreenRect:requested inWindow:window];
            NSRect actual = window.mouseConfinementRect, frame = window.frame;
            if (NSIsEmptyRect(expected) || confinement_rect_close(actual, expected)) { attempted = NO; return; }
            // Don't continually reapply a request Wine/macOS cannot accept. A changed window,
            // clip request, native rectangle or focus state permits a fresh attempt.
            if (attempted && lastWindow == window.windowNumber && confinement_rect_close(lastActual, actual) &&
                confinement_rect_close(lastExpected, expected) && confinement_rect_close(lastFrame, frame)) return;
            attempted = YES; lastWindow = window.windowNumber; lastActual = actual; lastExpected = expected; lastFrame = frame;
            BOOL ok = [handler startClippingCursor:requested];
            note(@"borderless mouse bounds: %@ -> %@ (Wine requested %@), %@; actual now %@",
                 NSStringFromRect(actual), NSStringFromRect(expected), NSStringFromRect(NSRectFromCGRect(requested)),
                 ok ? @"refreshed" : @"request declined", NSStringFromRect(window.mouseConfinementRect));
        } @catch (__unused NSException *exception) { /* Unknown driver layouts stay untouched. */ }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    note(@"borderless mouse bounds watcher installed (raw capture independent)");
}
