import SwiftUI
import AppKit
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
    /// Shown inside the Profiles tab (no Done button; stacks when narrow).
    var embedded = false

    @State private var layerIndex = 0
    @State private var selection: Part = .input(.a)
    @State private var family: Controllers.Family?
    /// Not observed here: the live test updates many times a second, and redrawing the whole editor would close any open menu.
    @State private var tester = PadTester()
    @State private var newLayerName = ""
    @State private var addingLayer = false
    @State private var renamingLayer = false

    enum Part: Hashable { case input(PadProfiles.Input), stick(Int), gyro, triggers }

    init(profile: PadProfiles.Profile, own: Bool, gameName: String, all: [PadProfiles.Profile], embedded: Bool = false, onChange: @escaping (PadProfiles.Profile) -> Void) {
        _profile = State(initialValue: profile)
        self.own = own; self.gameName = gameName; self.all = all; self.onChange = onChange; self.embedded = embedded
    }

    /// Everything resolved, for showing what comes from profiles underneath.
    var everything: [PadProfiles.Profile] { all.filter { $0.id != profile.id } + [profile] }
    var merged: (layers: [(name: String, bindings: [PadProfiles.Input: PadProfiles.Binding])], left: PadProfiles.Stick, right: PadProfiles.Stick, gyro: PadProfiles.Gyro, triggers: PadProfiles.Triggers) {
        PadProfiles.merged(profile, all: everything)
    }
    var layerName: String { layerIndex == 0 ? "Base" : profile.layers[layerIndex].name }
    /// What this button does here without a setting of its own: the same layer in profiles underneath, and in a
    /// layer the base layer (a layer only changes what you change in it).
    func inherited(_ i: PadProfiles.Input) -> PadProfiles.Binding? {
        let m = merged
        if let b = m.layers.first(where: { $0.name.caseInsensitiveCompare(layerName) == .orderedSame })?.bindings[i] { return b }
        guard layerIndex > 0 else { return nil }
        return profile.layers[0][i] ?? m.layers.first?.bindings[i]
    }

    func left(_ width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            layerBar
            ControllerPicture(family: family, selection: $selection, tester: tester,
                              mapped: { i in profile.layers[layerIndex][i] != nil || inherited(i) != nil },
                              label: { i in shortLabel(i) })
                .frame(width: width, height: width * 400 / 560)
            ExtraButtons(tester: tester, family: family, selection: $selection,
                         mapped: { i in profile.layers[layerIndex][i] != nil || inherited(i) != nil })
            PadTestView(tester: tester, family: family)
        }
        .frame(width: width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // The picture shrinks to leave the settings their room.
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 16) {
                    ScrollView { left(max(330, min(560, geo.size.width - 416))) }
                        .scrollIndicators(.never)
                        .frame(width: max(330, min(560, geo.size.width - 416)))
                    Form { inspector }.formStyle(.grouped).frame(minWidth: 380, maxWidth: .infinity)
                }
            }
            if !embedded {
                HStack {
                    Text("Changes are saved as you make them and apply on the next press, even while playing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(embedded ? 16 : 20)
        .frame(minWidth: embedded ? 720 : 1020, minHeight: embedded ? 500 : 720)
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
            Menu("Quick Setup") {
                Button(swapped(.a, .b) ? "Unswap A and B" : "Swap A and B") { swap(.a, .b) }
                Button(swapped(.x, .y) ? "Unswap X and Y" : "Swap X and Y") { swap(.x, .y) }
                Divider()
                Button("Clear \(layerIndex == 0 ? "the Base Layer" : layerName)") { profile.layers[layerIndex].bindings = [:] }
            }
            .fixedSize()
            .help("Swapped buttons reach Windows games as each other (Nintendo-style A and B, for example).")
        }
    }

    func swapped(_ a: PadProfiles.Input, _ b: PadProfiles.Input) -> Bool {
        profile.layers[layerIndex][a]?.press == [.pad(b)] && profile.layers[layerIndex][b]?.press == [.pad(a)]
    }
    func swap(_ a: PadProfiles.Input, _ b: PadProfiles.Input) {
        if swapped(a, b) { profile.layers[layerIndex][a] = nil; profile.layers[layerIndex][b] = nil }
        else { profile.layers[layerIndex][a] = .as(.pad(b)); profile.layers[layerIndex][b] = .as(.pad(a)) }
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
        Section {
            BindingEditor(binding: bindingFor(i), input: i, family: family, layers: profile.layers.dropFirst().map(\.name),
                          inLayer: layerIndex > 0, inherited: from.map(describe))
        } header: {
            InspectorTitle(title: i.title(family), subtitle: layerIndex > 0 ? "\(layerName) layer" : nil, symbol: i.isTrigger ? "l2.button.roundedtop.horizontal" : "circle.circle")
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
        Section {
            Picker("Works as", selection: st.mode) { ForEach(PadProfiles.StickMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            switch st.wrappedValue.mode {
            case .mouse:
                slider("Speed", st.speed, 200...6000, "%.0f /s")
                axisSliders(x: Binding(get: { st.wrappedValue.xScale ?? 1 }, set: { var v = st.wrappedValue; v.xScale = $0 == 1 ? nil : $0; st.wrappedValue = v }),
                            y: Binding(get: { st.wrappedValue.yScale ?? 1 }, set: { var v = st.wrappedValue; v.yScale = $0 == 1 ? nil : $0; st.wrappedValue = v }))
            case .flick:
                slider("One full turn", st.countsPerTurn, 500...20000, "%.0f", info: "Mouse movement that turns the game's camera all the way round. Flick the stick right: it should turn exactly 90°.")
                slider("Flick time", st.flickTime, 0...0.3, "%.2f s")
            case .keys:
                ForEach(0..<4, id: \.self) { k in
                    Picker(["Up", "Down", "Left", "Right"][k], selection: Binding(get: { st.wrappedValue.keys.indices.contains(k) ? st.wrappedValue.keys[k] : 13 },
                                                  set: { v in var x = st.wrappedValue; if x.keys.count < 4 { x.keys = [13, 1, 0, 2] }; x.keys[k] = v; st.wrappedValue = x })) {
                        ForEach(PadProfiles.keys) { Text($0.title).tag($0.code) }
                    }
                }
            default: EmptyView()
            }
        } header: {
            InspectorTitle(title: s == 0 ? "Left Stick" : "Right Stick", subtitle: nil, symbol: s == 0 ? "l.joystick" : "r.joystick")
        } footer: {
            if st.wrappedValue.mode == .flick {
                Text("Push the stick to the edge to turn to face that way; rotate it around the edge to keep turning. Pairs well with gyro aim.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if st.wrappedValue.mode == .mouse {
            Section("Acceleration") {
                Picker("Curve", selection: Binding(get: { CurvePreset.of(st.wrappedValue.curve) }, set: { var v = st.wrappedValue; if let c = $0.value { v.curve = c }; st.wrappedValue = v })) {
                    ForEach(CurvePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                slider("Curve", st.curve, 0.5...4, "%.2f", info: "How speed rises as you push the stick: 1 is straight, higher starts slower for fine aim and still reaches full speed, below 1 is quicker off the centre.")
                CurveGraph(power: st.wrappedValue.curve, deadzone: st.wrappedValue.deadzone, boost: st.wrappedValue.edgeBoost ?? 0)
                    .frame(height: 90)
                slider("Speed up at the edge", Binding(get: { st.wrappedValue.edgeBoost ?? 0 }, set: { var v = st.wrappedValue; v.edgeBoost = $0 < 0.025 ? nil : ($0 * 20).rounded() / 20; st.wrappedValue = v }),
                       0...3, "+%.0f%%", scale: 100, info: "Holding the stick all the way out speeds the turn up over time, for quick turns without making fine aim faster.")
                if (st.wrappedValue.edgeBoost ?? 0) > 0 {
                    slider("Over", Binding(get: { st.wrappedValue.edgeBoostTime ?? 0.4 }, set: { var v = st.wrappedValue; v.edgeBoostTime = $0; st.wrappedValue = v }), 0.05...2, "%.2f s")
                }
            }
        }
        if st.wrappedValue.mode != .off {
            if st.wrappedValue.mode == .stick || st.wrappedValue.mode == .otherStick {
                Section("Speed") {
                    axisSliders(x: Binding(get: { st.wrappedValue.xScale ?? 1 }, set: { var v = st.wrappedValue; v.xScale = $0 == 1 ? nil : $0; st.wrappedValue = v }),
                                y: Binding(get: { st.wrappedValue.yScale ?? 1 }, set: { var v = st.wrappedValue; v.yScale = $0 == 1 ? nil : $0; st.wrappedValue = v }))
                }
            }
            Section("Response") {
                slider("Dead zone", st.deadzone, 0...0.5, "%.2f", info: "How far the stick moves before it counts. Raise it if the stick drifts.")
                slider("Full at", st.outer, 0.5...1, "%.2f", info: "How far out the stick counts as fully pushed.")
                Toggle("Invert up and down", isOn: st.invertY)
            }
        }
        Section {
            BindingEditor(binding: bindingFor(s == 0 ? .ls : .rs), input: s == 0 ? .ls : .rs, family: family,
                          layers: profile.layers.dropFirst().map(\.name), inLayer: layerIndex > 0,
                          inherited: profile.layers[layerIndex][s == 0 ? .ls : .rs] == nil ? inherited(s == 0 ? .ls : .rs).map(describe) : nil)
        } header: { Text("Stick Click") } footer: {
            if (s == 0 ? profile.leftStick : profile.rightStick) != nil, !profile.buildsOn.isEmpty {
                Button("Use the Settings of the Profile Underneath") { if s == 0 { profile.leftStick = nil } else { profile.rightStick = nil } }.buttonStyle(.link).font(.caption)
            }
        }
    }

    var gyroBinding: Binding<PadProfiles.Gyro> {
        Binding(get: { profile.gyro ?? merged.gyro }, set: { profile.gyro = $0 })
    }

    @ViewBuilder var gyroInspector: some View {
        let g = gyroBinding
        Section {
            Picker("Moves", selection: g.output) { ForEach(PadProfiles.GyroOutput.allCases, id: \.self) { Text($0.title).tag($0) } }
            if g.wrappedValue.output != .off {
                Picker("When", selection: g.startsOn) {
                    Text("Always, unless a “Gyro off” button is held").tag(true)
                    Text("Only while a “Gyro on” button is held").tag(false)
                }
            }
        } header: {
            InspectorTitle(title: "Gyro", subtitle: nil, symbol: "gyroscope")
        } footer: {
            if g.wrappedValue.output != .off {
                Text(g.wrappedValue.startsOn ? "Give a button “Gyro off while held” to reposition the controller without turning, like lifting a mouse." : "Give a button “Gyro on while held”, for example the aim trigger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if g.wrappedValue.output != .off {
            Section("Left and right comes from") {
                slider("Turning (yaw)", Binding(get: { g.wrappedValue.yaw }, set: { var v = g.wrappedValue; v.yawAmount = ($0 * 20).rounded() / 20; v.rollAmount = v.roll; g.wrappedValue = v }),
                       0...2, "%.0f%%", scale: 100, info: "Turning the controller left and right, like turning a steering wheel lying flat.")
                slider("Tilting (roll)", Binding(get: { g.wrappedValue.roll }, set: { var v = g.wrappedValue; v.rollAmount = ($0 * 20).rounded() / 20; v.yawAmount = v.yaw; g.wrappedValue = v }),
                       0...2, "%.0f%%", scale: 100, info: "Tilting the controller sideways. Some players like a mix of both: it feels natural however you hold the controller.")
            }
        }
        if g.wrappedValue.output == .mouse {
            Section("Sensitivity") {
                slider("Sensitivity", g.sensitivity, 0.5...40, "%.1f", info: "Mouse movement per degree turned.")
                axisSliders(x: Binding(get: { g.wrappedValue.xScale ?? 1 }, set: { var v = g.wrappedValue; v.xScale = $0 == 1 ? nil : $0; g.wrappedValue = v }),
                            y: Binding(get: { g.wrappedValue.yScale ?? 1 }, set: { var v = g.wrappedValue; v.yScale = $0 == 1 ? nil : $0; g.wrappedValue = v }))
                Toggle("Faster when turning fast", isOn: Binding(get: { g.wrappedValue.fastSensitivity != nil },
                                                               set: { var x = g.wrappedValue; x.fastSensitivity = $0 ? x.sensitivity * 2 : nil; g.wrappedValue = x }))
                if g.wrappedValue.fastSensitivity != nil {
                    slider("Fast sensitivity", Binding(get: { g.wrappedValue.fastSensitivity ?? 0 }, set: { var x = g.wrappedValue; x.fastSensitivity = $0; g.wrappedValue = x }), 0.5...80, "%.1f")
                    slider("Slow below", g.slowSpeed, 0...100, "%.0f °/s")
                    slider("Fast above", g.fastSpeed, 10...400, "%.0f °/s")
                }
            }
        } else if g.wrappedValue.output != .off {
            Section("Stick") {
                slider("Full push at", g.stickFullSpeed, 30...720, "%.0f °/s", info: "Turning this fast pushes the stick all the way.")
                slider("Least push", g.stickMinimum, 0...0.5, "%.2f", info: "Games ignore small stick movements; this starts beyond their dead zone.")
            }
        }
        if g.wrappedValue.output != .off {
            Section("Steadiness") {
                slider("Smoothing below", g.smoothing, 0...20, "%.1f °/s", info: "Slow movements are averaged for steadier aim; fast ones stay instant. 0 is off.")
                slider("Steady below", g.tightening, 0...10, "%.1f °/s", info: "Very small movements (hand shake) are scaled down. 0 is off.")
                Toggle("Invert left and right", isOn: g.invertX)
                Toggle("Invert up and down", isOn: g.invertY)
                Toggle("Calibrate when the controller is still", isOn: g.autoCalibrate)
            }
        }
        if profile.gyro != nil, !profile.buildsOn.isEmpty {
            Section { Button("Use the Gyro of the Profile Underneath") { profile.gyro = nil }.buttonStyle(.link) }
        }
    }

    @ViewBuilder var triggerInspector: some View {
        let t = Binding(get: { profile.triggers ?? merged.triggers }, set: { profile.triggers = $0 })
        Section {
            slider("Pressed at", t.soft, 0.05...0.9, "%.0f%%", scale: 100, info: "How far a trigger is pulled to count as pressed when it's set to a key or button.")
            slider("Full pull at", t.full, 0.5...1, "%.0f%%", scale: 100, info: "When \(PadProfiles.Input.ltfull.title(family)) and \(PadProfiles.Input.rtfull.title(family)) count: a second action at the end of the pull.")
        } header: {
            InspectorTitle(title: "Trigger Pull", subtitle: nil, symbol: "r2.button.roundedtop.horizontal")
        } footer: {
            Text("A trigger with nothing set stays a trigger. Set \(PadProfiles.Input.rt.title(family)) and \(PadProfiles.Input.rtfull.title(family)) to different things for a two-stage trigger.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Left/right and up/down speed as percentages of the main setting.
    @ViewBuilder func axisSliders(x: Binding<Double>, y: Binding<Double>) -> some View {
        slider("Left and right", Binding(get: { x.wrappedValue }, set: { x.wrappedValue = ($0 * 20).rounded() / 20 }), 0.25...3, "%.0f%%", scale: 100,
               info: "Speed of left and right movement compared with the main speed (100% is the same).")
        slider("Up and down", Binding(get: { y.wrappedValue }, set: { y.wrappedValue = ($0 * 20).rounded() / 20 }), 0.25...3, "%.0f%%", scale: 100,
               info: "Many players like up and down a little slower than left and right.")
    }

    func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String, scale: Double = 1, info: String? = nil) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: v, in: range).frame(minWidth: 120)
                Text(String(format: fmt, v.wrappedValue * scale)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        } label: {
            HStack(spacing: 4) { Text(title); if let info { InfoButton(info) } }
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
    var inherited: String? = nil
    @State private var more = false

    enum Kind: String, CaseIterable { case same, press, taps }
    var kind: Kind {
        guard let b = binding, !(b.press.isEmpty && b.tap.isEmpty && b.hold.isEmpty && b.double.isEmpty) else { return .same }
        return (!b.tap.isEmpty || !b.hold.isEmpty || !b.double.isEmpty) ? .taps : .press
    }

    var body: some View {
        Picker("Does", selection: Binding(get: { kind }, set: setKind)) {
            Text(inLayer ? "As underneath" : "Itself").tag(Kind.same)
            Text("Something else").tag(Kind.press)
            Text("Tap / Hold").tag(Kind.taps)
        }
        .pickerStyle(.segmented)
        if kind == .same, let inherited {
            LabeledContent(inLayer ? "From underneath" : "From the profile underneath") { Text(inherited).foregroundStyle(.secondary) }
        }
        if let b = binding {
            switch kind {
            case .press:
                OutputsEditor(title: "Press", outputs: field(\.press), family: family, layers: layers)
                Toggle("Repeat while held", isOn: Binding(get: { (b.turbo ?? 0) > 0 }, set: { binding?.turbo = $0 ? 100 : nil }))
                if let t = b.turbo, t > 0 {
                    LabeledContent("Every") { Stepper("\(t) ms", value: Binding(get: { t }, set: { binding?.turbo = $0 }), in: 30...1000, step: 10) }
                }
            case .taps:
                OutputsEditor(title: "Tap", outputs: field(\.tap), family: family, layers: layers)
                OutputsEditor(title: "Hold", outputs: field(\.hold), family: family, layers: layers)
                OutputsEditor(title: "Double tap", outputs: field(\.double), family: family, layers: layers)
                LabeledContent("Hold after") {
                    Stepper("\(Int((b.holdTime ?? 0.2) * 1000)) ms", value: Binding(get: { b.holdTime ?? 0.2 }, set: { binding?.holdTime = $0 }), in: 0.08...1, step: 0.02)
                }
            case .same: EmptyView()
            }
        }
        DisclosureGroup("More", isExpanded: Binding(get: { more || binding?.together != nil }, set: { more = $0 })) {
            Picker("Pressed together with", selection: Binding(get: { binding?.together }, set: { v in
                var b = binding ?? PadProfiles.Binding()
                b.together = v
                if v != nil && b.togetherOutputs.isEmpty { b.togetherOutputs = [.nothing] }
                if v == nil { b.togetherOutputs = [] }
                binding = b.isEmpty && b.together == nil ? nil : b
            })) {
                Text("Nothing").tag(PadProfiles.Input?.none)
                ForEach(PadProfiles.Input.allCases.filter { $0 != input }, id: \.self) { Text($0.title(family)).tag(PadProfiles.Input?.some($0)) }
            }
            .help("Both pressed at the same moment (within 1/20 s) do something else. This button then waits that long before acting alone.")
            if binding?.together != nil {
                OutputsEditor(title: "Together", outputs: field(\.togetherOutputs), family: family, layers: layers)
            }
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
}

/// The inspector's heading: what's selected, with its symbol.
struct InspectorTitle: View {
    let title: String
    let subtitle: String?
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// A list of things to do together (a combination), each removable, plus a menu to add another.
struct OutputsEditor: View {
    let title: String
    @Binding var outputs: [PadProfiles.Output]
    let family: Controllers.Family?
    let layers: [String]
    @State private var recording = false
    @State private var monitor: Any?
    @State private var heldModifiers = Set<Int>()

    func add(_ o: PadProfiles.Output) {
        if o == .nothing { outputs = [.nothing] } else { outputs.removeAll { $0 == .nothing }; if !outputs.contains(o) { outputs.append(o) } }
    }

    /// The next key, mouse button or scroll becomes an output. Modifiers held with a key are added too (Shift+R).
    func record() {
        recording = true; heldModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { e in
            switch e.type {
            case .flagsChanged:
                let k = Int(e.keyCode)
                let down: Bool = {
                    switch k {
                    case 56, 60: return e.modifierFlags.contains(.shift)
                    case 59, 62: return e.modifierFlags.contains(.control)
                    case 58, 61: return e.modifierFlags.contains(.option)
                    case 55, 54: return e.modifierFlags.contains(.command)
                    case 63: return e.modifierFlags.contains(.function)
                    case 57: return true
                    default: return false
                    }
                }()
                if down { heldModifiers.insert(k) }
                else if heldModifiers.contains(k) {      // a modifier pressed and let go on its own
                    add(.key(k)); stopRecording()
                }
                return nil
            case .keyDown:
                for m in heldModifiers.sorted() { add(.key(m)) }
                add(.key(Int(e.keyCode))); stopRecording(); return nil
            case .leftMouseDown: add(.mouse(.left)); stopRecording(); return nil
            case .rightMouseDown: add(.mouse(.right)); stopRecording(); return nil
            case .otherMouseDown:
                add(.mouse(e.buttonNumber == 2 ? .middle : e.buttonNumber == 3 ? .back : .forward)); stopRecording(); return nil
            case .scrollWheel:
                guard abs(e.scrollingDeltaY) > 0.5 else { return nil }
                add(.wheel(up: e.scrollingDeltaY > 0)); stopRecording(); return nil
            default: return e
            }
        }
    }
    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; recording = false; heldModifiers = []
    }

    var body: some View {
        LabeledContent(title) {
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
                Menu(outputs.isEmpty ? "Choose" : "Add") { OutputMenu(family: family, layers: layers) { o in add(o) } }
                    .fixedSize()
                Button(recording ? "Press a key or click…" : "Press…") { recording ? stopRecording() : record() }
                    .help("Press a key, or click or scroll the mouse inside this window, to add it. Press the button again to stop.")
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
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


/// Paddles, touchpad and the like: buttons that don't fit the picture.
struct ExtraButtons: View {
    @ObservedObject var tester: PadTester
    let family: Controllers.Family?
    @Binding var selection: ControllerProfileEditor.Part
    let mapped: (PadProfiles.Input) -> Bool

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach([PadProfiles.Input.paddle1, .paddle2, .paddle3, .paddle4, .touchpad, .misc], id: \.self) { i in
                Button { selection = .input(i) } label: {
                    Text(i.title(family)).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tester.pressed.contains(i) ? Color.accentColor.opacity(0.6) : mapped(i) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selection == .input(i) ? Color.accentColor : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
            Button { selection = .triggers } label: { Text("Trigger pull").font(.caption) }.buttonStyle(.link)
        }
    }
}


enum CurvePreset: String, CaseIterable {
    case quick, straight, smooth, precise, custom
    var title: String { switch self { case .quick: "Quick off the centre"; case .straight: "Straight"; case .smooth: "Smooth"; case .precise: "Precise"; case .custom: "Custom" } }
    var value: Double? { switch self { case .quick: 0.7; case .straight: 1; case .smooth: 1.5; case .precise: 2.5; case .custom: nil } }
    static func of(_ v: Double) -> CurvePreset { allCases.first { $0.value.map { abs($0 - v) < 0.01 } ?? false } ?? .custom }
}

/// Output speed against how far the stick is pushed (with the dead zone and edge speed-up).
struct CurveGraph: View {
    let power: Double, deadzone: Double, boost: Double
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, top = 1 + boost
            var grid = Path()
            for f in [0.25, 0.5, 0.75] { grid.move(to: CGPoint(x: w * f, y: 0)); grid.addLine(to: CGPoint(x: w * f, y: h)) }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            var curve = Path()
            for i in 0...100 {
                let x = Double(i) / 100
                let r = x <= deadzone ? 0 : (x - deadzone) / (1 - deadzone)
                let y = pow(r, power) / top
                let p = CGPoint(x: x * w, y: h - y * h)
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
            if boost > 0 {
                var b = Path(); b.move(to: CGPoint(x: w, y: h - h / top)); b.addLine(to: CGPoint(x: w, y: 0))
                ctx.stroke(b, with: .color(.accentColor.opacity(0.6)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .accessibilityLabel("Speed curve")
    }
}
