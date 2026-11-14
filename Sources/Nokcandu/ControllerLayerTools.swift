import SwiftUI
import AppKit
import NokcanduCore

// Layer colours, layer tabs, assigning by pressing, and copying settings between layers.

extension ControllerProfileEditor {
    // MARK: Colours

    /// Colours for layers that haven't been given one, by position: Base blue, then distinct hues.
    static let layerPalette = ["#3478F6", "#FF8C1A", "#34C759", "#AF52DE", "#FF375F", "#30B0C7", "#FFCC00", "#A2845E"]

    /// A layer's colour: its own (also the controller's light) or the palette's for its position.
    func layerColor(_ i: Int) -> Color {
        let hex = profile.layers.indices.contains(i) ? profile.layers[i].color : nil
        let rgb = PadFeedback.rgb(hex ?? Self.layerPalette[i % Self.layerPalette.count]) ?? (0.2, 0.47, 0.96)
        return Color(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2))
    }
    func indexOfLayer(named name: String) -> Int? {
        profile.layers.indices.first { $0 > 0 && profile.layers[$0].name.caseInsensitiveCompare(name) == .orderedSame }
    }
    /// The layer a button switches to (hold or toggle), if it does.
    func switchTarget(_ b: PadProfiles.Binding?) -> Int? {
        guard let b else { return nil }
        for o in b.press + b.tap + b.hold + b.double + b.togetherOutputs {
            switch o {
            case .layerHold(let n), .layerToggle(let n): if let i = indexOfLayer(named: n) { return i }
            default: break
            }
        }
        return nil
    }

    /// What the layer being edited changes compared with the base layer (for the dots on the picture).
    func changedInLayer(_ i: PadProfiles.Input) -> Bool { layerIndex > 0 && profile.layers[layerIndex][i] != nil }
    func stickChangedInLayer(_ s: Int) -> Bool {
        guard layerIndex > 0 else { return false }
        let l = profile.layers[layerIndex]
        let own = (s == 0 ? l.leftStick : l.rightStick) != nil
        let pad = inputSource == .steamUSB && s == 1 && l.steamRightTrackpad != nil
        return own || pad || PadProfiles.Input.stickDirections(s).contains { l[$0] != nil }
    }

    // MARK: Layer tabs

    /// The layers as coloured tabs (a segmented control can't show colours).
    var layerTabs: some View {
        HStack(spacing: 4) {
            ForEach(profile.layers.indices, id: \.self) { i in
                let on = i == layerIndex
                Button { layerIndex = i } label: {
                    HStack(spacing: 5) {
                        Circle().fill(layerColor(i)).frame(width: 8, height: 8)
                        Text(i == 0 ? "Base" : profile.layers[i].name).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? layerColor(i).opacity(0.28) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? layerColor(i) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(i == 0 ? "The base layer" : "Edit the \(profile.layers[i].name) layer")
            }
        }
    }

    /// The colour of the layer being edited (it is also the controller's light on DualSense and DualShock 4).
    var layerColorPicker: some View {
        ColorPicker("Layer colour", selection: Binding(get: { layerColor(layerIndex) }, set: { profile.layers[layerIndex].color = Self.hex($0) }),
                    supportsOpacity: false)
            .labelsHidden()
            .help("This layer's colour here, and the controller's light while it's on (DualSense, DualShock 4).")
    }

    // MARK: Duplicate and copy

    func duplicateLayer() {
        guard profile.layers.count < 8 else { return }
        var copy = profile.layers[layerIndex]
        copy.id = UUID().uuidString
        let base = layerIndex == 0 ? "Base" : copy.name
        var n = "\(base) copy", k = 2
        while indexOfLayer(named: n) != nil { n = "\(base) copy \(k)"; k += 1 }
        copy.name = n
        copy.color = Self.layerPalette[profile.layers.count % Self.layerPalette.count]
        if layerIndex == 0 {
            // The base layer's own stick, gyro and pad settings are the profile's: give the copy them as its own.
            copy.leftStick = profile.leftStick; copy.rightStick = profile.rightStick; copy.gyro = profile.gyro
            copy.steamLeftTrackpad = profile.steamLeftTrackpad; copy.steamRightTrackpad = profile.steamRightTrackpad
        }
        profile.layers.append(copy)
        layerIndex = profile.layers.count - 1
    }

    /// Layers other than the one being edited, for "Copy from".
    var otherLayers: [Int] { profile.layers.indices.filter { $0 != layerIndex } }
    func layerTitle(_ i: Int) -> String { i == 0 ? "Base" : profile.layers[i].name }

    /// "Copy from ▸ layer" for one input: what it does there (own or inherited) becomes its setting here.
    func copyInputMenu(_ input: PadProfiles.Input) -> some View {
        Menu("Copy from") {
            ForEach(otherLayers, id: \.self) { l in
                Button(layerTitle(l)) { profile.layers[layerIndex][input] = profile.layers[l][input] ?? (l > 0 ? profile.layers[0][input] : nil) }
            }
        }
        .fixedSize()
        .help("Use what this does in another layer.")
    }

    /// "Copy from ▸ layer" for a stick: its settings and its four directions.
    func copyStickMenu(_ s: Int) -> some View {
        Menu("Copy from") {
            ForEach(otherLayers, id: \.self) { l in
                Button(layerTitle(l)) {
                    let src = l == 0 ? baseStick(s) : ((s == 0 ? profile.layers[l].leftStick : profile.layers[l].rightStick) ?? baseStick(s))
                    if layerIndex == 0 { if s == 0 { profile.leftStick = src } else { profile.rightStick = src } }
                    else if s == 0 { profile.layers[layerIndex].leftStick = src } else { profile.layers[layerIndex].rightStick = src }
                    for d in PadProfiles.Input.stickDirections(s) + [s == 0 ? .ls : .rs] {
                        profile.layers[layerIndex][d] = profile.layers[l][d] ?? (l > 0 ? profile.layers[0][d] : nil)
                    }
                }
            }
        }
        .fixedSize()
        .help("Use this stick's settings, directions and click from another layer.")
    }

    func copyGyroMenu() -> some View {
        Menu("Copy from") {
            ForEach(otherLayers, id: \.self) { l in
                Button(layerTitle(l)) {
                    let base = profile.gyro ?? merged.gyro
                    let src = l == 0 ? base : (profile.layers[l].gyro ?? base)
                    if layerIndex == 0 { profile.gyro = src } else { profile.layers[layerIndex].gyro = src }
                }
            }
        }
        .fixedSize()
        .help("Use the gyro settings from another layer.")
    }

    func copyPadMenu(_ side: Int) -> some View {
        Menu("Copy from") {
            ForEach(otherLayers, id: \.self) { l in
                Button(layerTitle(l)) {
                    let base = baseSteamPad(side)
                    let src = l == 0 ? base : ((side == 0 ? profile.layers[l].steamLeftTrackpad : profile.layers[l].steamRightTrackpad) ?? base)
                    if layerIndex == 0 { if side == 0 { profile.steamLeftTrackpad = src } else { profile.steamRightTrackpad = src } }
                    else if side == 0 { profile.layers[layerIndex].steamLeftTrackpad = src } else { profile.layers[layerIndex].steamRightTrackpad = src }
                    for d in PadProfiles.Input.padDirections(side) {
                        profile.layers[layerIndex][d] = profile.layers[l][d] ?? (l > 0 ? profile.layers[0][d] : nil)
                    }
                }
            }
        }
        .fixedSize()
        .help("Use this trackpad's settings and directions from another layer.")
    }
}

// MARK: Assign by pressing

/// While on: a controller button pressed in the editor is selected, and the next key or mouse button pressed
/// on the Mac becomes what it does in the layer being edited. Off, pressing buttons just tests them.
@MainActor final class AssignByPressing: ObservableObject {
    @Published var on = false { didSet { if !on { cancel() } } }
    /// The button waiting for its key.
    @Published private(set) var waiting: PadProfiles.Input?
    private var monitor: Any?
    private var lastPressed: Set<PadProfiles.Input> = []
    private var assign: ((PadProfiles.Input, PadProfiles.Output) -> Void)?

    /// The tester's pressed buttons changed.
    func pressedChanged(_ now: Set<PadProfiles.Input>, select: (PadProfiles.Input) -> Void,
                        assign: @escaping (PadProfiles.Input, PadProfiles.Output) -> Void) {
        defer { lastPressed = now }
        guard on, let first = now.subtracting(lastPressed).sorted(by: { $0.rawValue < $1.rawValue }).first else { return }
        self.assign = assign
        select(first)
        waiting = first
        listen()
    }

    /// Assigns a left click (the mouse's left button also clicks around the editor, so it's a button here).
    func assignLeftClick() { finish(.mouse(.left)) }

    func cancel() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        waiting = nil
    }

    private func finish(_ o: PadProfiles.Output) {
        if let w = waiting { assign?(w, o) }
        cancel()
    }

    private func listen() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, self.waiting != nil else { return e }
            switch e.type {
            case .keyDown:
                if e.keyCode == 53 { self.cancel() } else { self.finish(.key(Int(e.keyCode))) }   // Escape cancels
                return nil
            case .flagsChanged:
                let k = Int(e.keyCode)
                let down: Bool
                switch k {
                case 56, 60: down = e.modifierFlags.contains(.shift)
                case 59, 62: down = e.modifierFlags.contains(.control)
                case 58, 61: down = e.modifierFlags.contains(.option)
                case 55, 54: down = e.modifierFlags.contains(.command)
                case 57: down = true
                default: return e
                }
                if down { self.finish(.key(k)); return nil }
                return e
            case .rightMouseDown: self.finish(.mouse(.right)); return nil
            case .otherMouseDown:
                let b: PadProfiles.MouseButton = e.buttonNumber == 3 ? .back : e.buttonNumber == 4 ? .forward : .middle
                self.finish(.mouse(b)); return nil
            default: return e
            }
        }
    }
}

/// The switch above the picture, and what it's waiting for.
struct AssignBar: View {
    @ObservedObject var assign: AssignByPressing
    let title: (PadProfiles.Input) -> String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $assign.on) {
                Label("Assign by pressing", systemImage: "hand.point.up.left")
            }
            .toggleStyle(.switch).controlSize(.small)
            .help("Press a button on the controller, then the key or mouse button it should be. Off: pressing buttons only tests them.")
            if assign.on {
                HStack(spacing: 8) {
                    if let w = assign.waiting {
                        Text("\(title(w)): press a key or mouse button…").font(.callout.weight(.medium)).foregroundStyle(tint)
                        Button("Left Click") { assign.assignLeftClick() }.controlSize(.small)
                        Button("Cancel") { assign.cancel() }.controlSize(.small)
                    } else {
                        Text("Press a button on the controller.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
            }
        }
    }
}
