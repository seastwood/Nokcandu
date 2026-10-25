// Prints the main display's current scaled (logical) desktop size, e.g. "1470 956".
// Same behavior as the kit's screen-size.swift; falls back to the validated recovery size.
import CoreGraphics

if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0, mode.height > 0 {
    print("\(mode.width) \(mode.height)")
} else {
    print("1280 800")
}
