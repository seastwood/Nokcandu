// SPDX-License-Identifier: GPL-3.0-only
// The Mac's displays, for choosing where a stream plays and what picture size "This Mac's display" asks for.
import AppKit
import CoreGraphics

enum StreamDisplays {
    /// A display's stable ID (Core Graphics' UUID: the same across restarts and reconnections).
    static func id(_ s: NSScreen) -> String? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    static func isBuiltIn(_ s: NSScreen) -> Bool {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(n.uint32Value) != 0
    }

    /// The display a stream plays on: the chosen one when it's connected, otherwise the one Nokcandu's window is on.
    static func screen(for id: String?) -> NSScreen? {
        if let id, let s = NSScreen.screens.first(where: { Self.id($0) == id }) { return s }
        return current
    }

    /// The display the user is working on: Nokcandu's main window's, else the one with the pointer.
    static var current: NSScreen? {
        if let w = NSApp.windows.first(where: { $0.isVisible && !($0.windowController is StreamWindowController) && $0.styleMask.contains(.titled) && ($0.isMainWindow || $0.isKeyWindow) }), let s = w.screen { return s }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    }

    /// The picture size, in pixels, that fills the display: full screen stops below a notch.
    static func pixels(_ s: NSScreen, fullScreen: Bool) -> CGSize {
        var usable = s.frame.size
        if fullScreen, s.safeAreaInsets.top > 0 { usable.height -= s.safeAreaInsets.top }
        let scale = s.backingScaleFactor
        return CGSize(width: (usable.width * scale / 2).rounded() * 2, height: (usable.height * scale / 2).rounded() * 2)
    }

    static func label(_ s: NSScreen) -> String {
        let px = pixels(s, fullScreen: true)
        let name = isBuiltIn(s) ? "Built-in display" : s.localizedName
        return "\(name) (\(Int(px.width))×\(Int(px.height)))"
    }
}
