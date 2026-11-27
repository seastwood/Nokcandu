import AppKit
import NokcanduCore

/// Keys a live controller profile types while Nokcandu itself is in front (testing a profile in the editor) are
/// dropped before they reach Nokcandu's own windows: a letter jumped the sidebar list to the first item starting with
/// it (type-select), Return or Space pressed buttons, and arrows moved the selection, pulling you out of what you were
/// testing. The editor's Test area reads the controller itself, so it still shows everything.
/// Kept: keys into a text field being edited (typing with a controller still works) and the Controller Input Test
/// window, which exists to show them. Mouse movement and clicks from the controller are unchanged.
enum OwnPadKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in drop(e) ? nil : e }
    }

    static func drop(_ e: NSEvent) -> Bool {
        guard let cg = e.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == PadEventSource.marker else { return false }
        let window = e.window ?? NSApp.keyWindow
        if window?.title == "Controller Input Test" { return false }
        if let text = window?.firstResponder as? NSTextView, text.isEditable { return false }
        return true
    }
}
