import AppKit
import SwiftUI
import GameController
import CoreHaptics
import NokcanduCore

/// A floating panel over everything (full-screen games too) that never takes clicks or the keyboard.
@MainActor
func padOverlayPanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.isFloatingPanel = true
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.ignoresMouseEvents = true
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.hidesOnDeactivate = false
    return p
}
@MainActor
private func screenUnderPointer() -> NSScreen? { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }

// MARK: - Radial menu

/// The ring shown while a radial menu's button is held: point a stick at a slice, let go to choose it.
@MainActor
final class RadialHUD {
    static let shared = RadialHUD()
    private var panel: NSPanel?
    private var titles: [String] = []
    private var name = ""

    func open(_ menu: PadProfiles.RadialMenu) {
        titles = menu.slices.map(\.title); name = menu.name
        update(-1)
    }
    func update(_ selected: Int) {
        let p = panel ?? padOverlayPanel()
        panel = p
        let host = NSHostingView(rootView: RadialView(name: name, titles: titles, selected: selected))
        host.frame.size = NSSize(width: 340, height: 340)
        p.contentView = host
        p.setContentSize(host.frame.size)
        if let f = screenUnderPointer()?.frame { p.setFrameOrigin(NSPoint(x: f.midX - 170, y: f.midY - 170)) }
        p.alphaValue = 1
        p.orderFrontRegardless()
    }
    func close() { panel?.orderOut(nil) }
}

private struct RadialView: View {
    let name: String
    let titles: [String]
    let selected: Int
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.72)).overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                let a = Double(i) / Double(max(titles.count, 1)) * 2 * .pi
                Text(t.isEmpty ? "—" : t)
                    .font(.system(size: 13, weight: i == selected ? .bold : .medium))
                    .foregroundStyle(i == selected ? Color.black : Color.white)
                    .lineLimit(2).multilineTextAlignment(.center).frame(width: 92)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(i == selected ? Color.white : Color.white.opacity(0.1)))
                    .offset(x: sin(a) * 118, y: -cos(a) * 118)
            }
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 100)
        }
        .frame(width: 320, height: 320)
        .padding(10)
    }
}

// MARK: - On-screen keyboard

/// A keyboard to type with the controller: the d-pad or left stick moves, A types, B deletes, X is space, Y shift,
/// LB/RB move the text cursor, Menu is Return; the button that opened it (or View) closes it.
@MainActor
final class OnScreenKeyboard: ObservableObject {
    static let shared = OnScreenKeyboard()
    @Published var row = 1
    @Published var col = 0
    @Published var shift = false
    private(set) var isOpen = false
    private var panel: NSPanel?
    var openedBy: Set<PadProfiles.Input> = []
    private var held: Set<PadProfiles.Input> = []
    private var lastMove = 0.0
    var type: (String) -> Void = { _ in }
    var key: (Int) -> Void = { _ in }

    static let rows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "⌫"],
        ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "?", "⏎"],
        ["⇧", "space", "←", "→", "esc", "done"],
    ]

    func toggle(pressed: Set<PadProfiles.Input>) { isOpen ? close() : open(pressed: pressed) }
    func open(pressed: Set<PadProfiles.Input>) {
        isOpen = true; openedBy = pressed; held = pressed; row = 1; col = 0
        let p = panel ?? padOverlayPanel()
        panel = p
        let host = NSHostingView(rootView: KeyboardView(kb: self))
        host.frame.size = host.fittingSize
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let f = screenUnderPointer()?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - host.fittingSize.width / 2, y: f.minY + 40)) }
        p.orderFrontRegardless()
        PadHUD.shared.show("On-screen keyboard", symbol: "keyboard")
    }
    func close() { isOpen = false; panel?.orderOut(nil) }

    /// The controller while the keyboard is open (instead of the profile).
    func handle(_ pressed: Set<PadProfiles.Input>, stick: CGPoint) {
        typealias I = PadProfiles.Input
        let new = pressed.subtracting(held)
        held = pressed
        // The opening button, let go and pressed again, closes it.
        if !openedBy.isDisjoint(with: new) || new.contains(.back) { close(); return }
        openedBy = openedBy.intersection(pressed)
        let now = ProcessInfo.processInfo.systemUptime
        var dx = 0, dy = 0
        if new.contains(.left) { dx = -1 }; if new.contains(.right) { dx = 1 }; if new.contains(.up) { dy = -1 }; if new.contains(.down) { dy = 1 }
        if dx == 0 && dy == 0 && now - lastMove > 0.18 {
            if stick.x > 0.6 { dx = 1 } else if stick.x < -0.6 { dx = -1 }
            if stick.y > 0.6 { dy = -1 } else if stick.y < -0.6 { dy = 1 }
            if dx != 0 || dy != 0 { lastMove = now }
        }
        if dy != 0 { row = (row + dy + Self.rows.count) % Self.rows.count; col = min(col, Self.rows[row].count - 1) }
        if dx != 0 { col = (col + dx + Self.rows[row].count) % Self.rows[row].count }
        if new.contains(.a) { press(Self.rows[row][col]) }
        if new.contains(.b) { key(51) }
        if new.contains(.x) { type(" ") }
        if new.contains(.y) { shift.toggle() }
        if new.contains(.lb) { key(123) }
        if new.contains(.rb) { key(124) }
        if new.contains(.start) { key(36) }
    }
    private func press(_ k: String) {
        switch k {
        case "⌫": key(51)
        case "⏎": key(36)
        case "⇧": shift.toggle()
        case "space": type(" ")
        case "←": key(123)
        case "→": key(124)
        case "esc": key(53)
        case "done": close()
        default:
            type(shift ? Self.shifted(k) : k)
            shift = false
        }
    }
    static func shifted(_ k: String) -> String {
        let m: [String: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                                   "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?"]
        return m[k] ?? k.uppercased()
    }
}

private struct KeyboardView: View {
    @ObservedObject var kb: OnScreenKeyboard
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(OnScreenKeyboard.rows.enumerated()), id: \.offset) { r, keys in
                HStack(spacing: 6) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { c, k in
                        let on = kb.row == r && kb.col == c
                        let label = k.count == 1 && kb.shift ? OnScreenKeyboard.shifted(k) : k
                        Text(label)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: k.count > 1 ? (k == "space" ? 200 : 64) : 40, height: 40)
                            .foregroundStyle(on ? Color.black : Color.white)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white : (k == "⇧" && kb.shift ? Color.white.opacity(0.4) : Color.white.opacity(0.12))))
                    }
                }
            }
            Text("A type · B delete · X space · Y shift · LB/RB move · Menu return · View close")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.78)))
        .padding(8)
        .fixedSize()
    }
}

// MARK: - Feedback on the controller

/// A short rumble, and the controller's light colour for a layer (DualSense, DualShock 4).
@MainActor
final class PadFeedback {
    static let shared = PadFeedback()
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    private var originalColor: [ObjectIdentifier: GCColor] = [:]

    func rumble(_ controllers: [GCController], strong: Bool = false) {
        for c in controllers {
            guard let h = c.haptics else { continue }
            let id = ObjectIdentifier(c)
            let engine = engines[id] ?? h.createEngine(withLocality: .default)
            guard let engine else { continue }
            engines[id] = engine
            do {
                try engine.start()
                let ev = strong
                    ? CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)], relativeTime: 0, duration: 0.4)
                    : CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)], relativeTime: 0)
                try engine.makePlayer(with: CHHapticPattern(events: [ev], parameters: [])).start(atTime: 0)
            } catch { engines[id] = nil }
        }
    }
    /// "#RRGGBB", or nil for the controller's own colour.
    func light(_ hex: String?, _ controllers: [GCController]) {
        for c in controllers {
            guard let l = c.light else { continue }
            let id = ObjectIdentifier(c)
            if let hex, let rgb = Self.rgb(hex) {
                if originalColor[id] == nil { originalColor[id] = l.color }
                l.color = GCColor(red: rgb.0, green: rgb.1, blue: rgb.2)
            } else if let o = originalColor[id] { l.color = o; originalColor[id] = nil }
        }
    }
    static func rgb(_ hex: String) -> (Float, Float, Float)? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return (Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255)
    }
}
