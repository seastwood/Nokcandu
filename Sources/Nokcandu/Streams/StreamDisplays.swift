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

    /// The panel's own pixels: its native display mode. A scaled "looks like" setting draws at a backing size that
    /// isn't the panel's (1470×956 pt is 2940×1912 on a 13-inch MacBook Air's 2560×1664 panel), and asking the host for that size
    /// meant an oversized picture scaled down again (the "Retina resolution" problem, November 19).
    static func nativePixels(_ s: NSScreen) -> CGSize {
        let backing = CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let modes = CGDisplayCopyAllDisplayModes(n.uint32Value, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode]
        else { return backing }
        let nativeFlag: UInt32 = 0x0200_0000          // kDisplayModeNativeFlag
        if let m = modes.first(where: { $0.ioFlags & nativeFlag != 0 }) { return CGSize(width: m.pixelWidth, height: m.pixelHeight) }
        if let m = modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) { return CGSize(width: m.pixelWidth, height: m.pixelHeight) }
        return backing
    }

    /// The picture size, in the panel's own pixels, that fills the display. Full screen stops below a notch unless
    /// `includeNotch` (the strip's height converted to panel pixels and the rest rounded to a multiple of 8, which
    /// gives 2560×1608 on a 13-inch MacBook Air).
    static func pixels(_ s: NSScreen, fullScreen: Bool, includeNotch: Bool = false) -> CGSize {
        let native = nativePixels(s)
        var height = native.height
        if fullScreen, !includeNotch, s.safeAreaInsets.top > 0 {
            let strip = s.safeAreaInsets.top * native.height / s.frame.height
            height = ((native.height - strip) / 8).rounded() * 8
        }
        return CGSize(width: (native.width / 2).rounded() * 2, height: (height / 2).rounded() * 2)
    }

    /// Whether the display has a camera housing (a strip that macOS's full screen leaves out).
    static func hasNotch(_ s: NSScreen) -> Bool { s.safeAreaInsets.top > 0 }

    /// Whether a picture of this size has the whole panel's shape on a display with a notch (2560×1664 on a 13-inch
    /// MacBook Air), so full screen should cover the strip beside the camera too rather than stop below it.
    static func fillsPanel(_ s: NSScreen, width: Int?, height: Int?) -> Bool {
        guard hasNotch(s), let width, let height, width > 0, height > 0 else { return false }
        let panel = nativePixels(s), below = pixels(s, fullScreen: true)
        let shape = Double(width) / Double(height)
        let panelShape = panel.width / panel.height, belowShape = below.width / below.height
        // Closer to the whole panel's shape than to the area below the notch.
        return abs(shape - panelShape) < abs(shape - belowShape) && abs(shape - panelShape) < 0.02
    }

    static func label(_ s: NSScreen) -> String {
        let px = pixels(s, fullScreen: true)
        let name = isBuiltIn(s) ? "Built-in display" : s.localizedName
        return "\(name) (\(Int(px.width))×\(Int(px.height)))"
    }
}
