// Opt-in workaround for a system arrow reappearing after Wine requests a hidden cursor.
// This follows Wine's visibility state only; it never captures, moves or accelerates input.
static IMP visibility_original;
static ptrdiff_t visibility_hidden = -1, visibility_target = -1, visibility_current = -1;
static char visibility_flag[PATH_MAX];
static BOOL visibility_enabled, visibility_blank;
static NSCursor *visibility_transparent;

static void visibility_update(id self, SEL sel, BOOL force) {
    ((void (*)(id, SEL, BOOL))visibility_original)(self, sel, force);
    BOOL hidden = *(BOOL *)((char *)(__bridge void *)self + visibility_hidden);
    void *target = *(void **)((char *)(__bridge void *)self + visibility_target);
    BOOL blank = visibility_enabled && hidden && NSApp.isActive && (force || target) &&
        [NSApp.keyWindow isKindOfClass:objc_getClass("WineWindow")];
    if (blank) {
        [visibility_transparent set];
        // Our bitmap replaces Wine's cached cursor. Make Wine reset its own cursor on its next
        // update, including when returning to menus or switching away, even if the handle is unchanged.
        *(BOOL *)((char *)(__bridge void *)self + visibility_current) = NO;
    }
    if (blank != visibility_blank) {
        visibility_blank = blank;
        note(@"cursor visibility: %@", blank ? @"hidden as requested by the game" : @"normal Wine cursor restored");
    }
}

static void install_cursor_visibility(void) {
    if (!visibility_flag[0] || access(visibility_flag, F_OK) != 0) return;
    Class cls = objc_getClass("WineApplicationController");
    Ivar hidden = cls ? class_getInstanceVariable(cls, "clientWantsCursorHidden") : NULL;
    Ivar target = cls ? class_getInstanceVariable(cls, "lastTargetWindow") : NULL;
    Ivar current = cls ? class_getInstanceVariable(cls, "cursorIsCurrent") : NULL;
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName("updateCursor:")) : NULL;
    char arg[8] = {0}, result[8] = {0};
    if (method) { method_getArgumentType(method, 2, arg, sizeof arg); method_getReturnType(method, result, sizeof result); }
    if (!hidden || !target || !current || !method || method_getNumberOfArguments(method) != 3 ||
        strcmp(ivar_getTypeEncoding(hidden), @encode(BOOL)) || strcmp(ivar_getTypeEncoding(current), @encode(BOOL)) ||
        ivar_getTypeEncoding(target)[0] != '@' || strcmp(arg, @encode(BOOL)) || strcmp(result, @encode(void))) {
        note(@"cursor visibility: unsupported Wine layout; left unchanged"); return;
    }
    visibility_hidden = ivar_getOffset(hidden); visibility_target = ivar_getOffset(target); visibility_current = ivar_getOffset(current);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
    if (!bitmap) return;
    memset(bitmap.bitmapData, 0, 4);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)]; [image addRepresentation:bitmap];
    visibility_transparent = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    visibility_enabled = YES;
    visibility_original = method_setImplementation(method, (IMP)visibility_update);
    // Keep the bitmap current after macOS cursor resets, independent of raw mouse capture.
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *t) {
        BOOL was = visibility_enabled; visibility_enabled = access(visibility_flag, F_OK) == 0;
        if (NSApp.isActive && (visibility_enabled || was || visibility_blank)) {
            id ctl = controller();
            if (ctl) visibility_update(ctl, sel_registerName("updateCursor:"), NO);
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    note(@"cursor visibility workaround installed (raw capture independent)");
}
