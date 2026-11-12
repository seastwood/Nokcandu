import SwiftUI
import AppKit
import NokcanduCore
import GameController

/// The profile's macros and radial menus (id, name), for menus and titles of outputs that name them.
struct PadExtras {
    var macros: [(String, String)] = []
    var menus: [(String, String)] = []
    func title(_ o: PadProfiles.Output, _ family: Controllers.Family?) -> String {
        switch o {
        case .macro(let id): return "Macro: " + (macros.first { $0.0 == id }?.1 ?? "removed")
        case .menu(let id): return "Radial menu: " + (menus.first { $0.0 == id }?.1 ?? "removed")
        default: return o.title(family)
        }
    }
}
private struct PadExtrasKey: EnvironmentKey { static let defaultValue = PadExtras() }
extension EnvironmentValues {
    var padExtras: PadExtras { get { self[PadExtrasKey.self] } set { self[PadExtrasKey.self] = newValue } }
}

extension ControllerProfileEditor {
    var layerNames: [String] { profile.layers.dropFirst().map(\.name) }

    func inputEditor(_ i: PadProfiles.Input, same: String = "Nothing") -> some View {
        BindingEditor(binding: bindingFor(i), input: i, family: family, layers: layerNames, inLayer: layerIndex > 0,
                      inherited: profile.layers[layerIndex][i] == nil ? inherited(i).map(describe) : nil, sameTitle: same)
    }

    // MARK: Touchpad

    @ViewBuilder var touchpadInspector: some View {
        if inputSource == .steamUSB { steamTrackpadInspector(0) }
        else { legacyTouchpadInspector }
    }
    @ViewBuilder var legacyTouchpadInspector: some View {
        let t = Binding(get: { profile.touchpad ?? PadProfiles.top(profile, all: everything, \.touchpad) ?? PadProfiles.Touchpad() }, set: { profile.touchpad = $0 })
        Section {
            Picker("Works as", selection: t.mode) { ForEach(PadProfiles.TouchMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            switch t.wrappedValue.mode {
            case .mouse:
                slider("Speed", Binding(get: { t.wrappedValue.speed ?? 1500 }, set: { var v = t.wrappedValue; v.speed = $0; t.wrappedValue = v }), 200...5000, "%.0f",
                       info: "Pointer movement for a finger moved across the whole pad.")
                slider("Two-finger scrolling", Binding(get: { t.wrappedValue.scrollSpeed ?? 12 }, set: { var v = t.wrappedValue; v.scrollSpeed = $0; t.wrappedValue = v }), 2...60, "%.0f lines")
            case .scroll:
                slider("Scrolling", Binding(get: { t.wrappedValue.scrollSpeed ?? 12 }, set: { var v = t.wrappedValue; v.scrollSpeed = $0; t.wrappedValue = v }), 2...60, "%.0f lines",
                       info: "Lines scrolled for a finger moved from the top of the pad to the bottom.")
            default: EmptyView()
            }
        } header: {
            InspectorTitle(title: inputSource == .steamUSB ? "Left trackpad" : "Touchpad", subtitle: nil, symbol: "rectangle.and.hand.point.up.left")
        } footer: {
            Text(inputSource == .steamUSB ? "Original Steam Controller left trackpad. Its click is mapped as Left trackpad click. The right trackpad has its own behavior settings." : "DualSense and DualShock 4. Its click is set on the controller (Touchpad click)\(t.wrappedValue.mode == .zones ? "; with zones, clicking a zone set to something does that instead" : "").")
                .font(.caption).foregroundStyle(.secondary)
        }
        if t.wrappedValue.mode == .zones {
            Section("Touching a zone") { ForEach([PadProfiles.Input.tz1, .tz2, .tz3, .tz4], id: \.self) { i in LabeledContent(i.title(family)) { EmptyView() }; inputEditor(i) } }
            Section("Clicking in a zone") { ForEach([PadProfiles.Input.tc1, .tc2, .tc3, .tc4], id: \.self) { i in LabeledContent(i.title(family)) { EmptyView() }; inputEditor(i, same: "The touchpad click") } }
        }
    }

    // MARK: Tilt

    @ViewBuilder var tiltInspector: some View {
        let t = Binding(get: { profile.tilt ?? PadProfiles.top(profile, all: everything, \.tilt) ?? PadProfiles.Tilt() }, set: { profile.tilt = $0 })
        Section {
            slider("Tilt to count", Binding(get: { t.wrappedValue.angle ?? 30 }, set: { var v = t.wrappedValue; v.angle = $0.rounded(); t.wrappedValue = v }), 10...70, "%.0f°")
            Toggle("Swap left and right", isOn: Binding(get: { t.wrappedValue.invertX == true }, set: { var v = t.wrappedValue; v.invertX = $0 ? true : nil; t.wrappedValue = v }))
            Toggle("Swap forward and back", isOn: Binding(get: { t.wrappedValue.invertY == true }, set: { var v = t.wrappedValue; v.invertY = $0 ? true : nil; t.wrappedValue = v }))
        } header: {
            InspectorTitle(title: "Tilt", subtitle: nil, symbol: "level")
        } footer: {
            Text("Tilting the controller works like four more buttons (controllers with a gyro). Forward and back count from how you usually hold it. Try it in the test below.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(PadProfiles.Input.tilts, id: \.self) { i in Section(i.title(family)) { inputEditor(i) } }
    }

    // MARK: Macros

    var macrosBinding: Binding<[PadProfiles.Macro]> { Binding(get: { profile.macros ?? [] }, set: { profile.macros = $0.isEmpty ? nil : $0 }) }

    @ViewBuilder var macrosInspector: some View {
        Section {
            Text("A macro does several things in a row from one press — keys with pauses between them, holding a key, typing text. Give a button “Macro” in its menu to use one.")
                .font(.caption).foregroundStyle(.secondary)
            Button("New Macro") { macrosBinding.wrappedValue.append(PadProfiles.Macro(name: "Macro \(macrosBinding.wrappedValue.count + 1)", steps: [.init(.press, output: .key(49))])) }
                .disabled(macrosBinding.wrappedValue.count >= 16)
        } header: { InspectorTitle(title: "Macros", subtitle: nil, symbol: "list.bullet.rectangle") }
        ForEach(macrosBinding) { $m in
            Section {
                TextField("Name", text: $m.name)
                ForEach(Array(m.steps.enumerated()), id: \.offset) { i, _ in
                    MacroStepRow(step: Binding(get: { m.steps.indices.contains(i) ? m.steps[i] : .init(.wait) }, set: { if m.steps.indices.contains(i) { m.steps[i] = $0 } }),
                                 family: family, remove: { m.steps.remove(at: i) })
                }
                HStack {
                    Stepper("Between steps: \(m.eventDelayMS ?? 0) ms", value: Binding(get: { m.eventDelayMS ?? 0 }, set: { m.eventDelayMS = $0 }), in: 0...60000, step: 10)
                    Menu("Add Step") { ForEach(PadProfiles.Macro.Kind.allCases, id: \.self) { k in Button(k.title) { m.steps.append(.init(k, output: k == .wait || k == .text ? nil : .key(49), ms: k == .wait ? 50 : nil, text: k == .text ? "" : nil)) } } }
                        .fixedSize().disabled(m.steps.count >= 40)
                    MacroRecorder { m.steps += $0 }
                    Spacer()
                    Button("Delete Macro", role: .destructive) { macrosBinding.wrappedValue.removeAll { $0.id == m.id } }
                }
            }
        }
    }

    // MARK: Sequences

    var sequencesBinding: Binding<[PadProfiles.Sequence]> { Binding(get: { profile.sequences ?? [] }, set: { profile.sequences = $0.isEmpty ? nil : $0 }) }

    @ViewBuilder var sequencesInspector: some View {
        Section {
            Text("Buttons pressed one after another (up, up, down…) do something extra. Each button still does what it's set to, so pick buttons that don't get in the way, or set them to nothing.")
                .font(.caption).foregroundStyle(.secondary)
            Button("New Sequence") { sequencesBinding.wrappedValue.append(PadProfiles.Sequence(name: "Sequence \(sequencesBinding.wrappedValue.count + 1)", inputs: [.up, .up, .down], outputs: [.nothing])) }
                .disabled(sequencesBinding.wrappedValue.count >= 16)
        } header: { InspectorTitle(title: "Sequences", subtitle: nil, symbol: "arrow.triangle.turn.up.right.diamond") }
        ForEach(sequencesBinding) { $q in
            Section {
                TextField("Name", text: $q.name)
                LabeledContent("Buttons") {
                    FlowRow {
                        ForEach(Array(q.inputs.enumerated()), id: \.offset) { i, input in
                            HStack(spacing: 3) {
                                Text(input.title(family)).font(.callout)
                                Button { q.inputs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        Menu("Add") { ForEach(PadProfiles.Input.allCases.filter { !$0.isTrigger || $0 == .lt || $0 == .rt }, id: \.self) { i in Button(i.title(family)) { q.inputs.append(i) } } }
                            .fixedSize().disabled(q.inputs.count >= 8)
                        SequenceRecorder(tester: tester) { q.inputs.append($0) }.disabled(q.inputs.count >= 8)
                    }
                }
                slider("Most time between presses", Binding(get: { q.stepTime ?? 0.4 }, set: { q.stepTime = $0 }), 0.15...1.5, "%.2f s")
                OutputsEditor(title: "Does", outputs: $q.outputs, family: family, layers: layerNames)
                Button("Delete Sequence", role: .destructive) { sequencesBinding.wrappedValue.removeAll { $0.id == q.id } }
            } footer: {
                if q.inputs.count < 2 { Text("A sequence needs at least two presses.").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: Radial menus

    var menusBinding: Binding<[PadProfiles.RadialMenu]> { Binding(get: { profile.menus ?? [] }, set: { profile.menus = $0.isEmpty ? nil : $0 }) }

    @ViewBuilder var menusInspector: some View {
        Section {
            Text("Hold a button, point a stick or move the mouse/gyro toward a choice, then let go. Give a button “Radial menu” to open one. The selected stick or mapped mouse movement selects the menu while it is open.")
                .font(.caption).foregroundStyle(.secondary)
            Button("New Radial Menu") {
                menusBinding.wrappedValue.append(PadProfiles.RadialMenu(name: "Menu \(menusBinding.wrappedValue.count + 1)", slices: (0..<4).map { _ in .init(title: "", outputs: [.nothing]) }))
            }.disabled(menusBinding.wrappedValue.count >= 8)
        } header: { InspectorTitle(title: "Radial Menus", subtitle: nil, symbol: "circle.grid.cross") }
        ForEach(menusBinding) { $mn in
            Section {
                TextField("Name", text: $mn.name)
                Picker("Pick with", selection: $mn.stick) { Text("Left stick").tag(0); Text("Right stick").tag(1); Text("Mouse / gyro direction").tag(2) }
                ForEach(Array(mn.slices.enumerated()), id: \.offset) { i, _ in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                            TextField("Title", text: Binding(get: { mn.slices.indices.contains(i) ? mn.slices[i].title : "" }, set: { if mn.slices.indices.contains(i) { mn.slices[i].title = $0 } }), prompt: Text(mn.slices[i].displayTitle(family)))
                            Button { mn.slices.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove choice")
                        }
                        OutputsEditor(title: "Does", outputs: Binding(get: { mn.slices.indices.contains(i) ? mn.slices[i].outputs : [] }, set: { if mn.slices.indices.contains(i) { mn.slices[i].outputs = $0 } }),
                                      family: family, layers: layerNames)
                    }
                }
                HStack {
                    Button("Add Choice") { mn.slices.append(.init(title: "", outputs: [.nothing])) }.disabled(mn.slices.count >= 8)
                    Spacer()
                    Button("Delete Menu", role: .destructive) { menusBinding.wrappedValue.removeAll { $0.id == mn.id } }
                }
            } footer: { Text("Choices go clockwise from the top. Leave Title blank to use the action’s name, or type your own.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Feedback

    @ViewBuilder var feedbackInspector: some View {
        Section {
            LabeledContent("Rumble") { Button("Test Rumble") { PadFeedback.shared.rumble(GCController.controllers(), strong: true) } }
            Toggle("Rumble when the layer changes", isOn: Binding(get: { profile.rumbleOnLayer ?? PadProfiles.top(profile, all: everything, \.rumbleOnLayer) ?? false }, set: { profile.rumbleOnLayer = $0 }))
            ForEach(profile.layers.indices, id: \.self) { l in
                LabeledContent(l == 0 ? "Light: Base" : "Light: \(profile.layers[l].name)") {
                    HStack {
                        if let hex = profile.layers[l].color, let rgb = PadFeedback.rgb(hex) {
                            ColorPicker("", selection: Binding(get: { Color(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2)) },
                                                               set: { profile.layers[l].color = Self.hex($0) }), supportsOpacity: false).labelsHidden()
                            Button { profile.layers[l].color = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("The controller's own colour")
                        } else {
                            Button("Set Colour") { profile.layers[l].color = l == 0 ? "#3478F6" : "#FF8C1A" }
                        }
                    }
                }
            }
        } header: {
            InspectorTitle(title: "Feedback", subtitle: nil, symbol: "waveform")
        } footer: {
            Text("The light is on DualSense and DualShock 4 controllers; rumble on controllers macOS can rumble (give a button “Rumble” to buzz on purpose). Games' own vibration reaches the controller as usual. The on-screen note (Settings) shows layer changes too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

/// One step of a macro.
struct MacroStepRow: View {
    @Binding var step: PadProfiles.Macro.Step
    let family: Controllers.Family?
    let remove: () -> Void
    @Environment(\.padExtras) var extras
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { step.kind }, set: { k in
                step.kind = k
                if k == .wait && step.ms == nil { step.ms = 50 }
                if (k == .press || k == .down || k == .up) && step.output == nil { step.output = .key(49) }
                if k == .text && step.text == nil { step.text = "" }
            })) { ForEach(PadProfiles.Macro.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .labelsHidden().frame(width: 110)
            switch step.kind {
            case .chord:
                OutputsEditor(title: "Chord", outputs: Binding(get: { step.outputs ?? [] }, set: { step.outputs = $0 }), family: family, layers: [])
            case .wait:
                Stepper("\(step.ms ?? 50) ms", value: Binding(get: { step.ms ?? 50 }, set: { step.ms = $0 }), in: 0...60000, step: 10)
            case .text:
                TextField("Text to type", text: Binding(get: { step.text ?? "" }, set: { step.text = $0 }))
            default:
                Menu(step.output.map { extras.title($0, family) } ?? "Choose") {
                    OutputMenu(family: family, layers: []) { o in if o.macroFree { step.output = o } }
                }.fixedSize()
            }
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove step")
        }
    }
}

/// Records keys as you press them (with the pauses between), as macro steps.
struct MacroRecorder: View {
    let add: ([PadProfiles.Macro.Step]) -> Void
    @State private var monitor: Any?
    @State private var steps: [PadProfiles.Macro.Step] = []
    @State private var last = 0.0
    var body: some View {
        Button(monitor == nil ? "Record…" : "Stop Recording") { monitor == nil ? start() : stop() }
            .foregroundStyle(monitor == nil ? Color.primary : Color.accentColor)
            .help("Type in this window: each key, with the pauses between, becomes steps. Press again to stop.")
            .onDisappear { if monitor != nil { stop() } }
    }
    func start() {
        steps = []; last = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            if e.type == .keyDown && e.isARepeat { return nil }
            let t = e.timestamp
            if last > 0 { let ms = Int(((t - last) * 1000).rounded()); if ms >= 10 { steps.append(.init(.wait, ms: ms)) } }
            last = t
            let k = Int(e.keyCode)
            switch e.type {
            case .keyDown: steps.append(.init(.down, output: .key(k)))
            case .keyUp: steps.append(.init(.up, output: .key(k)))
            default:
                let down = !(steps.contains { $0.kind == .down && $0.output == .key(k) } && !steps.contains { $0.kind == .up && $0.output == .key(k) })
                steps.append(.init(down ? .down : .up, output: .key(k)))
            }
            return nil
        }
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        // A quick down-and-up of the same key reads as one press.
        var out: [PadProfiles.Macro.Step] = []
        var i = 0
        while i < steps.count {
            if steps[i].kind == .down, i + 2 < steps.count, steps[i + 1].kind == .wait, (steps[i + 1].ms ?? 0) <= 150, steps[i + 2].kind == .up, steps[i + 2].output == steps[i].output {
                out.append(.init(.press, output: steps[i].output)); i += 3
            } else if steps[i].kind == .down, i + 1 < steps.count, steps[i + 1].kind == .up, steps[i + 1].output == steps[i].output {
                out.append(.init(.press, output: steps[i].output)); i += 2
            } else { out.append(steps[i]); i += 1 }
        }
        if !out.isEmpty { add(Array(out.prefix(40))) }
        steps = []
    }
}

/// Adds the controller buttons you press, in order, while it's on.
struct SequenceRecorder: View {
    @ObservedObject var tester: PadTester
    let add: (PadProfiles.Input) -> Void
    @State private var on = false
    var body: some View {
        Button(on ? "Stop" : "Press on Controller…") { on.toggle() }
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .help("Press the buttons of the sequence on your controller, then click Stop.")
            .onChange(of: tester.pressed) { old, new in
                guard on else { return }
                for i in new.subtracting(old).sorted(by: { $0.rawValue < $1.rawValue }) where !i.isTrigger || i == .lt || i == .rt { add(i) }
            }
    }
}
