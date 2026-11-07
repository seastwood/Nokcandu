import SwiftUI
import NokcanduCore

/// Editing a controller profile: a picture of the controller (click a button, stick or the gyro), layers, what
/// the selected part does, and a live test that shows what the game would get.
struct ControllerProfileEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: PadProfiles.Profile
    let own: Bool
    let gameName: String
    let all: [PadProfiles.Profile]
    let onChange: (PadProfiles.Profile) -> Void

    @State private var layerIndex = 0
    @State private var selection: Part = .input(.a)
    @State private var family: Controllers.Family?
    @StateObject private var tester = PadTester()
    @State private var newLayerName = ""
    @State private var addingLayer = false
    @State private var renamingLayer = false

    enum Part: Hashable { case input(PadProfiles.Input), stick(Int), gyro, triggers }

    init(profile: PadProfiles.Profile, own: Bool, gameName: String, all: [PadProfiles.Profile], onChange: @escaping (PadProfiles.Profile) -> Void) {
        _profile = State(initialValue: profile)
        self.own = own; self.gameName = gameName; self.all = all; self.onChange = onChange
    }

    /// Everything resolved, for showing what comes from profiles underneath.
    var everything: [PadProfiles.Profile] { all.filter { $0.id != profile.id } + [profile] }
    var merged: (layers: [(name: String, bindings: [PadProfiles.Input: PadProfiles.Binding])], left: PadProfiles.Stick, right: PadProfiles.Stick, gyro: PadProfiles.Gyro, triggers: PadProfiles.Triggers) {
        PadProfiles.merged(profile, all: everything)
    }
    var layerName: String { layerIndex == 0 ? "Base" : profile.layers[layerIndex].name }
    func inherited(_ i: PadProfiles.Input) -> PadProfiles.Binding? {
        merged.layers.first { $0.name.caseInsensitiveCompare(layerName) == .orderedSame }?.bindings[i]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    layerBar
                    ControllerPicture(family: family, selection: $selection, pressed: tester.pressed, sticks: tester.sticks,
                                      mapped: { i in profile.layers[layerIndex][i] != nil || inherited(i) != nil },
                                      label: { i in shortLabel(i) })
                        .frame(width: 440, height: 290)
                    extraButtons
                    PadTestView(tester: tester, family: family)
                }
                Divider()
                ScrollView { inspector.padding(.trailing, 8) }
                    .frame(minWidth: 340, maxWidth: .infinity)
            }
            HStack {
                Text("Changes are saved as you make them and apply on the next press, even while playing.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 660)
        .onAppear {
            family = Controllers.connected().first { $0.kind == .gamepad }?.family
            tester.start(profile: PadProfiles.compile(profile, all: everything))
        }
        .onDisappear { tester.stop() }
        .onChange(of: profile) { _, p in
            onChange(p)
            tester.reload(PadProfiles.compile(p, all: everything))
        }
        .alert(renamingLayer ? "Rename Layer" : "New Layer", isPresented: Binding(get: { addingLayer || renamingLayer }, set: { if !$0 { addingLayer = false; renamingLayer = false } })) {
            TextField("Name", text: $newLayerName)
            Button(renamingLayer ? "Rename" : "Add") { finishLayer() }.disabled(newLayerName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { addingLayer = false; renamingLayer = false }
        } message: {
            Text(renamingLayer ? "Buttons that switch to it follow the new name." : "Then give a button “\(newLayerName.isEmpty ? "the layer" : newLayerName) while held” or “on/off” in the base layer to reach it.")
        }
    }

    // MARK: Header and layers

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if own {
                Text("\(gameName)'s Controller Profile").font(.title2.bold())
            } else {
                TextField("Name", text: $profile.name).textFieldStyle(.plain).font(.title2.bold()).frame(maxWidth: 320)
            }
            Spacer()
            Picker("Labels", selection: $family) {
                Text("Xbox").tag(Controllers.Family?.none)
                Text("PlayStation").tag(Controllers.Family?.some(.playstation))
                Text("Nintendo").tag(Controllers.Family?.some(.nintendo))
                Text("Steam").tag(Controllers.Family?.some(.valve))
            }.frame(width: 200).help("Button names as printed on your controller")
            buildsOnMenu
        }
    }

    var buildsOnMenu: some View {
        let others = all.filter { $0.id != profile.id }
        let under = profile.buildsOn.compactMap { id in all.first { $0.id == id }?.name }
        return Menu(under.isEmpty ? "Builds on: nothing" : "Builds on: " + under.joined(separator: ", ")) {
            if others.isEmpty { Text("No other profiles yet") }
            ForEach(others) { o in
                Toggle(o.name, isOn: Binding(get: { profile.buildsOn.contains(o.id) }, set: { on in
                    if on { profile.buildsOn.append(o.id) } else { profile.buildsOn.removeAll { $0 == o.id } }
                }))
            }
        }
        .fixedSize()
        .help("Anything this profile doesn't set comes from the profiles it builds on (the last one wins).")
    }

    var layerBar: some View {
        HStack(spacing: 8) {
            Picker("Layer", selection: $layerIndex) {
                ForEach(profile.layers.indices, id: \.self) { i in Text(i == 0 ? "Base" : profile.layers[i].name).tag(i) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 320)
            Button { newLayerName = ""; addingLayer = true } label: { Image(systemName: "plus") }
                .help("Add a layer").disabled(profile.layers.count >= 8)
            if layerIndex > 0 {
                Menu {
                    Button("Rename…") { newLayerName = profile.layers[layerIndex].name; renamingLayer = true }
                    Button("Remove Layer", role: .destructive) { removeLayer() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
        }
    }

    func finishLayer() {
        let n = newLayerName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if renamingLayer {
            let old = profile.layers[layerIndex].name
            profile.layers[layerIndex].name = n
            renameLayerReferences(old, to: n)
        } else {
            profile.layers.append(PadProfiles.Layer(name: n))
            layerIndex = profile.layers.count - 1
        }
        addingLayer = false; renamingLayer = false
    }
    func renameLayerReferences(_ old: String, to new: String?) {
        func fix(_ o: [PadProfiles.Output]) -> [PadProfiles.Output] {
            o.compactMap { x in
                switch x {
                case .layerHold(let n) where n.caseInsensitiveCompare(old) == .orderedSame: return new.map { .layerHold($0) }
                case .layerToggle(let n) where n.caseInsensitiveCompare(old) == .orderedSame: return new.map { .layerToggle($0) }
                default: return x
                }
            }
        }
        for l in profile.layers.indices {
            for (k, b) in profile.layers[l].bindings {
                var c = b
                c.press = fix(b.press); c.tap = fix(b.tap); c.hold = fix(b.hold); c.double = fix(b.double); c.togetherOutputs = fix(b.togetherOutputs)
                profile.layers[l].bindings[k] = c.isEmpty ? nil : c
            }
        }
    }
    func removeLayer() {
        let old = profile.layers[layerIndex].name
        profile.layers.remove(at: layerIndex)
        renameLayerReferences(old, to: nil)
        layerIndex = 0
    }

    var extraButtons: some View {
        HStack(spacing: 6) {
            ForEach([PadProfiles.Input.paddle1, .paddle2, .paddle3, .paddle4, .touchpad, .misc], id: \.self) { i in
                Button { selection = .input(i) } label: {
                    Text(i.title(family)).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tester.pressed.contains(i) ? Color.accentColor.opacity(0.6) : (profile.layers[layerIndex][i] != nil || inherited(i) != nil) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selection == .input(i) ? Color.accentColor : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
            Button { selection = .triggers } label: { Text("Trigger pull").font(.caption) }.buttonStyle(.link)
        }
    }

    func shortLabel(_ i: PadProfiles.Input) -> String? {
        guard let b = profile.layers[layerIndex][i] ?? inherited(i) else { return nil }
        let first = b.press.first ?? b.tap.first ?? b.hold.first ?? b.togetherOutputs.first
        guard let o = first else { return nil }
        switch o {
        case .key(let k): return PadProfiles.keyTitle(k).replacingOccurrences(of: "Left ", with: "L").replacingOccurrences(of: "Right ", with: "R")
        case .mouse(let m): return m == .left ? "LMB" : m == .right ? "RMB" : m == .middle ? "MMB" : m == .back ? "M4" : "M5"
        case .pad(let p): return p.title(family)
        case .trigger(let r): return r ? "RT" : "LT"
        case .wheel(let up): return up ? "Wh↑" : "Wh↓"
        case .gyroOn, .gyroOff, .gyroToggle: return "Gyro"
        case .layerHold(let n), .layerToggle(let n): return String(n.prefix(4))
        case .nothing: return "—"
        }
    }

    // MARK: Inspector

    @ViewBuilder var inspector: some View {
        switch selection {
        case .input(let i): inputInspector(i)
        case .stick(let s): stickInspector(s)
        case .gyro: gyroInspector
        case .triggers: triggerInspector
        }
    }

    func bindingFor(_ i: PadProfiles.Input) -> Binding<PadProfiles.Binding?> {
        Binding(get: { profile.layers[layerIndex][i] }, set: { profile.layers[layerIndex][i] = $0 })
    }

    @ViewBuilder func inputInspector(_ i: PadProfiles.Input) -> some View {
        let own = profile.layers[layerIndex][i]
        let from = own == nil ? inherited(i) : nil
        VStack(alignment: .leading, spacing: 10) {
            Text(i.title(family)).font(.title3.bold())
            if layerIndex > 0 { Text("In the \(layerName) layer").font(.caption).foregroundStyle(.secondary) }
            if let from {
                SettingNote("Comes from a profile this one builds on: \(describe(from)). Change it here to override it.")
            }
            BindingEditor(binding: bindingFor(i), input: i, family: family, layers: profile.layers.dropFirst().map(\.name),
                          inLayer: layerIndex > 0)
        }
    }

    func describe(_ b: PadProfiles.Binding) -> String {
        func o(_ x: [PadProfiles.Output]) -> String { x.map { $0.title(family) }.joined(separator: " + ") }
        var parts: [String] = []
        if !b.press.isEmpty { parts.append(o(b.press)) }
        if !b.tap.isEmpty { parts.append("tap: " + o(b.tap)) }
        if !b.hold.isEmpty { parts.append("hold: " + o(b.hold)) }
        if !b.double.isEmpty { parts.append("double tap: " + o(b.double)) }
        if let t = b.together, !b.togetherOutputs.isEmpty { parts.append("with \(t.title(family)): " + o(b.togetherOutputs)) }
        return parts.joined(separator: "; ")
    }

    func stickBinding(_ s: Int) -> Binding<PadProfiles.Stick> {
        Binding(get: { (s == 0 ? profile.leftStick : profile.rightStick) ?? (s == 0 ? merged.left : merged.right) },
                set: { if s == 0 { profile.leftStick = $0 } else { profile.rightStick = $0 } })
    }

    @ViewBuilder func stickInspector(_ s: Int) -> some View {
        let st = stickBinding(s)
        VStack(alignment: .leading, spacing: 10) {
            Text(s == 0 ? "Left Stick" : "Right Stick").font(.title3.bold())
            Picker("Works as", selection: st.mode) { ForEach(PadProfiles.StickMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            switch st.wrappedValue.mode {
            case .mouse:
                slider("Speed", st.speed, 200...6000, "%.0f /s")
                slider("Curve", st.curve, 1...3, "%.1f", info: "1 is straight; higher starts slower for fine aim and still reaches full speed.")
            case .flick:
                slider("One full turn", st.countsPerTurn, 500...20000, "%.0f", info: "Mouse movement that turns the game's camera all the way round. Find it by flicking the stick right: it should turn exactly 90°.")
                slider("Flick time", st.flickTime, 0...0.3, "%.2f s")
                SettingNote("Push the stick to the edge to turn to face that way; rotate it around the edge to keep turning. Combine with gyro aim for up and down.")
            case .keys:
                ForEach(0..<4, id: \.self) { k in
                    SettingRow(title: ["Up", "Down", "Left", "Right"][k]) {
                        Picker("", selection: Binding(get: { st.wrappedValue.keys.indices.contains(k) ? st.wrappedValue.keys[k] : 13 },
                                                      set: { v in var x = st.wrappedValue; if x.keys.count < 4 { x.keys = [13, 1, 0, 2] }; x.keys[k] = v; st.wrappedValue = x })) {
                            ForEach(PadProfiles.keys) { Text($0.title).tag($0.code) }
                        }.labelsHidden().frame(width: 160)
                    }
                }
            default: EmptyView()
            }
            if st.wrappedValue.mode != .off {
                slider("Dead zone", st.deadzone, 0...0.5, "%.2f", info: "How far the stick moves before it counts. Raise it if the stick drifts.")
                slider("Full at", st.outer, 0.5...1, "%.2f", info: "How far out the stick is fully pushed.")
                Toggle("Invert up and down", isOn: st.invertY)
            }
            Divider()
            Text("Stick click").font(.headline)
            BindingEditor(binding: bindingFor(s == 0 ? .ls : .rs), input: s == 0 ? .ls : .rs, family: family,
                          layers: profile.layers.dropFirst().map(\.name), inLayer: layerIndex > 0)
            if (s == 0 ? profile.leftStick : profile.rightStick) != nil {
                Button("Use the Profile Underneath's Settings") { if s == 0 { profile.leftStick = nil } else { profile.rightStick = nil } }.buttonStyle(.link)
            }
        }
    }

    var gyroBinding: Binding<PadProfiles.Gyro> {
        Binding(get: { profile.gyro ?? merged.gyro }, set: { profile.gyro = $0 })
    }

    @ViewBuilder var gyroInspector: some View {
        let g = gyroBinding
        VStack(alignment: .leading, spacing: 10) {
            Text("Gyro").font(.title3.bold())
            Picker("Moves", selection: g.output) { ForEach(PadProfiles.GyroOutput.allCases, id: \.self) { Text($0.title).tag($0) } }
            if g.wrappedValue.output != .off {
                Picker("Turning left and right comes from", selection: g.turn) { ForEach(PadProfiles.GyroTurn.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle("On until a “Gyro off” button is held", isOn: g.startsOn)
                SettingNote(g.wrappedValue.startsOn
                            ? "Give a button “Gyro off while held” to reposition the controller without turning (like lifting a mouse)."
                            : "The gyro only moves while a button set to “Gyro on while held” is held (for example while aiming).")
                if g.wrappedValue.output == .mouse {
                    slider("Sensitivity", g.sensitivity, 0.5...40, "%.1f", info: "Mouse movement per degree turned.")
                    Toggle("Faster when turning fast", isOn: Binding(get: { g.wrappedValue.fastSensitivity != nil },
                                                                   set: { var x = g.wrappedValue; x.fastSensitivity = $0 ? x.sensitivity * 2 : nil; g.wrappedValue = x }))
                    if g.wrappedValue.fastSensitivity != nil {
                        slider("Fast sensitivity", Binding(get: { g.wrappedValue.fastSensitivity ?? 0 }, set: { var x = g.wrappedValue; x.fastSensitivity = $0; g.wrappedValue = x }), 0.5...80, "%.1f")
                        slider("Slow below", g.slowSpeed, 0...100, "%.0f °/s")
                        slider("Fast above", g.fastSpeed, 10...400, "%.0f °/s")
                    }
                } else {
                    slider("Full push at", g.stickFullSpeed, 30...720, "%.0f °/s", info: "Turning this fast pushes the stick all the way.")
                    slider("Least push", g.stickMinimum, 0...0.5, "%.2f", info: "Games ignore small stick movements; this starts beyond their dead zone.")
                }
                slider("Smoothing below", g.smoothing, 0...20, "%.1f °/s", info: "Slow movements are averaged for steadier aim; fast ones stay instant. 0 is off.")
                slider("Steady below", g.tightening, 0...10, "%.1f °/s", info: "Very small movements (hand shake) are scaled down. 0 is off.")
                Toggle("Invert left and right", isOn: g.invertX)
                Toggle("Invert up and down", isOn: g.invertY)
                Toggle("Calibrate when the controller is still", isOn: g.autoCalibrate)
                SettingNote("Put the controller down for a moment if the aim slowly drifts.")
            }
            if profile.gyro != nil { Button("Use the Profile Underneath's Gyro") { profile.gyro = nil }.buttonStyle(.link) }
        }
    }

    @ViewBuilder var triggerInspector: some View {
        let t = Binding(get: { profile.triggers ?? merged.triggers }, set: { profile.triggers = $0 })
        VStack(alignment: .leading, spacing: 10) {
            Text("Trigger Pull").font(.title3.bold())
            slider("Pressed at", t.soft, 0.05...0.9, "%.0f%%", scale: 100, info: "How far a trigger is pulled to count as pressed when it's set to a key or button.")
            slider("Full pull at", t.full, 0.5...1, "%.0f%%", scale: 100, info: "The full-pull inputs (\(PadProfiles.Input.ltfull.title(family)), \(PadProfiles.Input.rtfull.title(family))): a second action at the end of the pull.")
            SettingNote("A trigger with nothing set stays a trigger. Set \(PadProfiles.Input.rt.title(family)) and \(PadProfiles.Input.rtfull.title(family)) to two different things for a two-stage trigger.")
        }
    }

    func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String, scale: Double = 1, info: String? = nil) -> some View {
        SettingRow(title: title, info: info) {
            Slider(value: v, in: range).frame(width: 150)
            Text(String(format: fmt, v.wrappedValue * scale)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - What one button does

struct BindingEditor: View {
    @Binding var binding: PadProfiles.Binding?
    let input: PadProfiles.Input
    let family: Controllers.Family?
    let layers: [String]
    let inLayer: Bool

    enum Kind: String, CaseIterable { case same, press, taps }
    var kind: Kind {
        guard let b = binding else { return .same }
        return (!b.tap.isEmpty || !b.hold.isEmpty || !b.double.isEmpty) ? .taps : .press
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Does", selection: Binding(get: { kind }, set: setKind)) {
                Text(inLayer ? "Same as underneath" : "Itself").tag(Kind.same)
                Text("Something else").tag(Kind.press)
                Text("Tap, hold or double tap").tag(Kind.taps)
            }
            .pickerStyle(.radioGroup)
            if let b = binding {
                switch kind {
                case .press:
                    OutputsEditor(title: "Press", outputs: field(\.press), family: family, layers: layers)
                    turbo(b)
                case .taps:
                    OutputsEditor(title: "Tap", outputs: field(\.tap), family: family, layers: layers)
                    OutputsEditor(title: "Hold", outputs: field(\.hold), family: family, layers: layers)
                    OutputsEditor(title: "Double tap", outputs: field(\.double), family: family, layers: layers)
                    SettingRow(title: "Hold after", info: "How long a press lasts before it counts as a hold.") {
                        Stepper("\(Int((b.holdTime ?? 0.2) * 1000)) ms", value: Binding(get: { b.holdTime ?? 0.2 }, set: { binding?.holdTime = $0 }), in: 0.08...1, step: 0.02)
                    }
                case .same: EmptyView()
                }
            }
            Divider()
            together
        }
    }

    func field(_ k: WritableKeyPath<PadProfiles.Binding, [PadProfiles.Output]>) -> Binding<[PadProfiles.Output]> {
        Binding(get: { binding?[keyPath: k] ?? [] }, set: { v in var b = binding ?? PadProfiles.Binding(); b[keyPath: k] = v; binding = b })
    }

    func setKind(_ k: Kind) {
        switch k {
        case .same:
            if let t = binding?.together, let o = binding?.togetherOutputs, !o.isEmpty { binding = PadProfiles.Binding(together: t, togetherOutputs: o) }
            else { binding = nil }
        case .press:
            var b = binding ?? PadProfiles.Binding()
            if b.press.isEmpty { b.press = b.tap.isEmpty ? [.nothing] : b.tap }
            b.tap = []; b.hold = []; b.double = []
            binding = b
        case .taps:
            var b = binding ?? PadProfiles.Binding()
            if b.tap.isEmpty { b.tap = b.press.isEmpty ? (input.isTrigger ? [.nothing] : [.pad(input)]) : b.press }
            if b.hold.isEmpty { b.hold = [.nothing] }
            b.press = []; b.turbo = nil
            binding = b
        }
    }

    @ViewBuilder func turbo(_ b: PadProfiles.Binding) -> some View {
        SettingToggle(title: "Repeat while held", info: "Presses again and again while you hold the button (turbo).",
                      isOn: Binding(get: { (b.turbo ?? 0) > 0 }, set: { binding?.turbo = $0 ? 100 : nil }))
        if let t = b.turbo, t > 0 {
            SettingRow(title: "Every") {
                Stepper("\(t) ms", value: Binding(get: { t }, set: { binding?.turbo = $0 }), in: 30...1000, step: 10)
            }
        }
    }

    @ViewBuilder var together: some View {
        let others = PadProfiles.Input.allCases.filter { $0 != input }
        SettingRow(title: "Pressed together with", info: "Both pressed at the same moment (within 1/20 s) do something else. This button then waits that long before acting alone.") {
            Picker("", selection: Binding(get: { binding?.together }, set: { v in
                var b = binding ?? PadProfiles.Binding()
                b.together = v
                if v != nil && b.togetherOutputs.isEmpty { b.togetherOutputs = [.nothing] }
                if v == nil { b.togetherOutputs = [] }
                binding = b.isEmpty && b.together == nil ? nil : b
            })) {
                Text("Nothing").tag(PadProfiles.Input?.none)
                ForEach(others, id: \.self) { Text($0.title(family)).tag(PadProfiles.Input?.some($0)) }
            }.labelsHidden().frame(width: 170)
        }
        if binding?.together != nil {
            OutputsEditor(title: "Together", outputs: field(\.togetherOutputs), family: family, layers: layers)
        }
    }
}

/// A list of things to do together (a combination), each removable, plus a menu to add another.
struct OutputsEditor: View {
    let title: String
    @Binding var outputs: [PadProfiles.Output]
    let family: Controllers.Family?
    let layers: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: 78, alignment: .leading)
            FlowRow {
                ForEach(Array(outputs.enumerated()), id: \.offset) { i, o in
                    HStack(spacing: 3) {
                        Text(o.title(family)).font(.callout)
                        Button { outputs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(o.title(family))")
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Menu(outputs.isEmpty ? "Choose" : "Add") { OutputMenu(family: family, layers: layers) { o in
                    if o == .nothing { outputs = [.nothing] } else { outputs.removeAll { $0 == .nothing }; if !outputs.contains(o) { outputs.append(o) } }
                } }
                .fixedSize()
            }
        }
    }
}

struct OutputMenu: View {
    let family: Controllers.Family?
    let layers: [String]
    let pick: (PadProfiles.Output) -> Void

    var body: some View {
        let keys = PadProfiles.keys
        Menu("Key") {
            Menu("Modifiers") { ForEach(keys.filter { [59, 62, 58, 61, 55, 54, 56, 60, 63, 57].contains($0.code) }) { k in Button(k.title) { pick(.key(k.code)) } } }
            Menu("Letters") { ForEach(keys.filter { $0.title.count == 1 && $0.title.first!.isLetter }) { k in Button(k.title) { pick(.key(k.code)) } } }
            Menu("Numbers") { ForEach(keys.filter { $0.title.count == 1 && $0.title.first!.isNumber }) { k in Button(k.title) { pick(.key(k.code)) } } }
            Menu("Function keys") { ForEach(keys.filter { $0.title.hasPrefix("F") && $0.title.count <= 3 && $0.title.dropFirst().allSatisfy(\.isNumber) }) { k in Button(k.title) { pick(.key(k.code)) } } }
            Menu("Keypad") { ForEach(keys.filter { $0.title.hasPrefix("Keypad") }) { k in Button(k.title) { pick(.key(k.code)) } } }
            Divider()
            ForEach(keys.filter { k in
                ![59, 62, 58, 61, 55, 54, 56, 60, 63, 57].contains(k.code) && !(k.title.count == 1 && (k.title.first!.isLetter || k.title.first!.isNumber))
                && !(k.title.hasPrefix("F") && k.title.count <= 3 && k.title.dropFirst().allSatisfy(\.isNumber)) && !k.title.hasPrefix("Keypad")
            }) { k in Button(k.title) { pick(.key(k.code)) } }
        }
        Menu("Mouse") {
            ForEach(PadProfiles.MouseButton.allCases, id: \.self) { m in Button(m.title) { pick(.mouse(m)) } }
            Button("Scroll up") { pick(.wheel(up: true)) }
            Button("Scroll down") { pick(.wheel(up: false)) }
        }
        Menu("Controller") {
            ForEach(PadProfiles.Input.padButtons, id: \.self) { i in Button(i.title(family)) { pick(.pad(i)) } }
            Divider()
            Button(PadProfiles.Input.lt.title(family)) { pick(.trigger(right: false)) }
            Button(PadProfiles.Input.rt.title(family)) { pick(.trigger(right: true)) }
        }
        Menu("Gyro") {
            Button("Gyro on while held") { pick(.gyroOn) }
            Button("Gyro off while held") { pick(.gyroOff) }
            Button("Gyro on/off") { pick(.gyroToggle) }
        }
        if !layers.isEmpty {
            Menu("Layer") {
                ForEach(layers, id: \.self) { n in
                    Button("\(n) while held") { pick(.layerHold(n)) }
                    Button("\(n) on/off") { pick(.layerToggle(n)) }
                }
            }
        }
        Divider()
        Button("Nothing") { pick(.nothing) }
    }
}

/// Lays out its children left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
