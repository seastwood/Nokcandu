import AppKit
import SwiftUI
import NokcanduCore

/// Window-local observation only. Never records text, installs a global tap, or posts events.
@MainActor
private final class PadInputReceipt: ObservableObject {
    var total = 0, mapped = 0
    var dx = 0.0, dy = 0.0
    var latest = "Click inside the test area to begin."
    var counts: [String: Int] = [:]
    var observation = PadInputObservation(start: ProcessInfo.processInfo.systemUptime)
    func reset() {
        total = 0; mapped = 0; dx = 0; dy = 0; counts = [:]; latest = "Counters reset."
        observation.reset(at: ProcessInfo.processInfo.systemUptime)
    }
    func interrupt() {
        observation.receive(.interrupted, mapped: false, at: ProcessInfo.processInfo.systemUptime)
    }
    private func keyName(_ code: Int) -> String { PadProfiles.keys.first { $0.code == code }?.title ?? "Key \(code)" }
    private func buttonName(_ code: Int) -> String {
        let names = ["Left", "Right", "Middle", "Back", "Forward"]
        return names.indices.contains(code) ? names[code] : "Button \(code)"
    }
    var heldKeys: String { observation.keys.isEmpty ? "None observed" : observation.keys.sorted().map(keyName).joined(separator: ", ") }
    var heldButtons: String { observation.buttons.isEmpty ? "None observed" : observation.buttons.sorted().map(buttonName).joined(separator: ", ") }
    var modifiers: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(observation.modifierFlags))
        let names: [(NSEvent.ModifierFlags, String)] = [(.shift,"Shift"),(.control,"Control"),(.option,"Option"),(.command,"Command"),(.function,"fn"),(.capsLock,"Caps Lock")]
        let active = names.filter { flags.contains($0.0) }.map { $0.1 }
        return active.isEmpty ? "None observed" : active.joined(separator: ", ")
    }
    var history: String {
        observation.history.map { entry in
            let action: String
            switch entry.input {
            case .key(let code, let down, let repeated): action = "\(keyName(code)) \(down ? "down" : "up")\(repeated ? " (repeat)" : "")"
            case .button(let button, let down): action = "\(buttonName(button)) mouse \(down ? "down" : "up")"
            case .modifiers(let flags): action = "Modifier flags \(flags)"
            case .interrupted: return String(format: "+%.3fs Window inactive — observation interrupted", entry.seconds)
            }
            return String(format: "+%.3fs %@: %@", entry.seconds, entry.mapped ? "Nokcandu" : "Other source", action)
        }.joined(separator: "\n")
    }
    var report: String {
        """
        Nokcandu window input test (receipt only)
        Received: \(total); Nokcandu: \(mapped)
        Movement: \(dx), \(dy)
        Observed held keys: \(heldKeys)
        Observed held mouse buttons: \(heldButtons)
        Observed modifiers: \(modifiers)
        Focus interrupted: \(observation.interrupted)
        Counts: \(counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", "))
        Last 32 key/button/modifier transitions (no typed characters):
        \(history)
        Observations start at Reset; releases outside this window may be missed. This does not verify game receipt.
        """
    }
    func receive(_ event: NSEvent) {
        total += 1
        let own = event.cgEvent.map { PadEventSource.isOwn($0, processID: ProcessInfo.processInfo.processIdentifier) } ?? false
        if own { mapped += 1 }
        let kind: String
        switch event.type {
        case .mouseMoved: kind = "Move"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = "Drag"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = "Button down"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = "Button up"
        case .keyDown: kind = "Key down"
        case .keyUp: kind = "Key up"
        case .flagsChanged: kind = "Modifiers"
        case .scrollWheel: kind = "Scroll"
        default: return
        }
        switch event.type {
        case .keyDown, .keyUp:
            observation.receive(.key(Int(event.keyCode), down: event.type == .keyDown, repeated: event.isARepeat), mapped: own, at: event.timestamp)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            observation.receive(.button(event.buttonNumber, down: true), mapped: own, at: event.timestamp)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            observation.receive(.button(event.buttonNumber, down: false), mapped: own, at: event.timestamp)
        case .flagsChanged:
            observation.receive(.modifiers(UInt64(event.modifierFlags.rawValue)), mapped: own, at: event.timestamp)
        default: break
        }
        counts[kind, default: 0] += 1
        let origin = own ? "Nokcandu" : "Other source"
        if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
            latest = "\(origin): \(kind), code \(event.keyCode), flags \(event.modifierFlags.rawValue)"
        } else {
            if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) {
                dx += event.deltaX; dy += event.deltaY
            }
            latest = String(format: "%@: %@, button %d, Δ %.2f / %.2f, location %.0f / %.0f", origin, kind, event.buttonNumber, event.deltaX, event.deltaY, event.locationInWindow.x, event.locationInWindow.y)
        }
    }
}

private struct PadReceiptArea: NSViewRepresentable {
    let receipt: PadInputReceipt
    final class Area: NSView {
        var monitor: Any?
        var focusObserver: NSObjectProtocol?
        var receipt: PadInputReceipt?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            focusObserver = nil
            guard let window else { return }
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receipt?.interrupt() }
            }
        }
        var tracking: NSTrackingArea?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {} // Test keys do not type or beep.
        override func keyUp(with event: NSEvent) {}
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
            tracking = next; addTrackingArea(next)
        }
    }
    func makeNSView(context: Context) -> Area {
        let view = Area()
        view.receipt = receipt
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp, .flagsChanged, .scrollWheel]) { [weak view] event in
            guard let window = view?.window, event.window === window else { return event }
            receipt.receive(event)
            return event
        }
        return view
    }
    func updateNSView(_ view: Area, context: Context) {}
    static func dismantleNSView(_ view: Area, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
        view.monitor = nil
        if let observer = view.focusObserver { NotificationCenter.default.removeObserver(observer) }
        view.focusObserver = nil; view.receipt = nil
    }
}

struct PadInputTest: View {
    @StateObject private var receipt = PadInputReceipt()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller Input Test").font(.title2)
            Text("Choose a Mac controller profile in Controls → Controller on the Mac, then click the area below and use your controller. This window observes its own input only; it does not generate input or record typed text.")
            PadReceiptArea(receipt: receipt).frame(minHeight: 180)
                .overlay(alignment: .topLeading) { Text("Click here, then move, click or press mapped keys.").foregroundStyle(.secondary).padding().allowsHitTesting(false) }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Received: \(receipt.total) · From Nokcandu: \(receipt.mapped)")
                    Text(String(format: "Accumulated movement: %.1f / %.1f", receipt.dx, receipt.dy))
                    Text("Observed held keys: \(receipt.heldKeys)")
                    Text("Observed held mouse buttons: \(receipt.heldButtons)")
                    Text("Modifiers: \(receipt.modifiers)")
                    if receipt.observation.interrupted {
                        Text("Focus was lost: held-state observation is incomplete. Return here and Reset before the next trial.").foregroundStyle(.orange)
                    }
                    Text(receipt.latest)
                    Text(receipt.counts.keys.sorted().map { "\($0): \(receipt.counts[$0] ?? 0)" }.joined(separator: " · "))
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Button("Reset Counters") { receipt.reset() }
                Button("Copy Test Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.report, forType: .string)
                }
            }
            DisclosureGroup("Recent key and button events") {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    ScrollView {
                        Text(receipt.history.isEmpty ? "No transitions observed since Reset." : receipt.history)
                            .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 130)
                }
            }
            Text("Held values are observations since Reset, not a global keyboard-state check. First release controls, click the test area, then Reset. Copy Test Report copies only this trial’s counters and last 32 control transitions; it does not save a file or send anything.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Receipt here verifies this window only. Games and streaming clients may consume input differently. System shortcuts can leave this window. Emergency capture release: Control–Option–Escape.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 660, minHeight: 580)
    }
}
