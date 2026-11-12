// Supported Nokcandu Wine drivers expose their current screen conversion. Keep
// layout validation in the same coordinate space as the event being validated.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#include <math.h>
static bool nokcandu_mouse_point(id controller, CGPoint point, bool to_windows, CGPoint *result)
{
    SEL conversion = NSSelectorFromString(to_windows ? @"nokcanduWindowsMousePoint:" : @"nokcanduMacMousePoint:");
    if (controller && [controller respondsToSelector:conversion])
        point = ((CGPoint (*)(id, SEL, CGPoint))objc_msgSend)(controller, conversion, point);
    if (!isfinite(point.x) || !isfinite(point.y)) return false;
    *result = point;
    return true;
}
static bool nokcandu_mouse_position_matches(int x, int y, CGPoint point, double tolerance)
{
    return isfinite(point.x) && isfinite(point.y) && fabs(x - floor(point.x)) <= tolerance && fabs(y - floor(point.y)) <= tolerance;
}

// While raw capture is aiming, the Mac pointer is frozen and the game's cursor lives in Wine. A click that
// carries the frozen pointer's position would move the game's cursor there, so on drivers that accept the
// position-free encoding (the one controller clicks use) the click keeps its button and loses its position.
// Returns the value to store in the event's button field; anything else is returned unchanged.
static int nokcandu_click_button(int button, bool aiming, bool positionless_supported)
{
    return aiming && positionless_supported && button >= 0 && button <= 4 ? -button - 1 : button;
}
