import AppKit
import SwiftUI

/// A layer sheet must own the real AppKit keyboard window, not only SwiftUI's
/// logical focus. Claim it once on presentation and again on an explicit click;
/// never poll or reclaim focus after the user switches to another application.
struct LayerNameField: NSViewRepresentable {
    @Binding var text: String
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LayerNameField
        init(_ parent: LayerNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }
    }
    final class Field: NSTextField {
        private var presented = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !presented, window != nil else { return }
            presented = true
            DispatchQueue.main.async { [weak self] in self?.claimKeyboard() }
        }
        private func claimKeyboard() {
            guard let window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(self)
        }
        override func mouseDown(with event: NSEvent) {
            claimKeyboard()
            super.mouseDown(with: event)
        }
    }
}
