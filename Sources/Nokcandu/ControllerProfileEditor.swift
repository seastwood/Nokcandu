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
    let editingContents: URL?

    @State var layerIndex = 0
    @State var selection: Part = .input(.a)
    @State private var undoStack: [PadProfiles.Profile] = []
    @State private var redoStack: [PadProfiles.Profile] = []
    @State private var lastUndoPush = 0.0
    @State private var undoing = false
    @State var family: Controllers.Family?
    /// Not observed here: the live test updates many times a second, and redrawing the whole editor would close any open menu.
    @State var tester = PadTester()
    @State private var newLayerName = ""
    @State private var addingLayer = false
    @State private var renamingLayer = false
    @State private var layerImportError: String?

    enum Part: Hashable {
        case input(PadProfiles.Input), stick(Int), gyro, triggers, deviceInput(String, String), deviceAxis(String, Int)
        case touchpad, tilt, macros, sequences, menus, feedback, headMotion
    }
    /// The device shown on the left instead of the controller (nil: the controller).
    @State private var shownDevice: String?

    init(profile: PadProfiles.Profile, own: Bool, gameName: String, all: [PadProfiles.Profile], embedded: Bool = false, editingContents: URL? = nil, onChange: @escaping (PadProfiles.Profile) -> Void) {
        _profile = State(initialValue: profile)
        self.editingContents = editingContents
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

    var inputSource: PadProfiles.ControllerSource { PadProfiles.top(profile, all: everything, \.controllerSource) ?? .automatic }

    var effectiveRouting: PadProfiles.RoutingMode { PadProfiles.top(profile, all: everything, \.routingMode) ?? .legacy }

    var selectedControlRoutes: [String] {
        switch selection {
        case .stick(let n): return [n == 0 ? "lstick" : "rstick"]
        case .gyro: return ["gyro"]
        case .touchpad: return ["touch"]
        case .tilt: return ["tilt"]
        case .triggers: return ["lt", "rt"]
        case .input(let input) where input.isTrigger: return [input == .lt || input == .ltfull ? "lt" : "rt"]
        default: return []
        }
    }

    static let routeTitles = ["lstick": "Left stick", "rstick": "Right stick", "gyro": "Gyro", "touch": "Touchpad", "tilt": "Tilt", "lt": "Left trigger", "rt": "Right trigger"]

    /// One row above the picture: its name (with the explanation behind an (i)), then its menu, which
    /// shortens its own text rather than pushing the row wider than the pane.
    func sourceRow<Control: View>(_ title: String, info: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).fixedSize()
            if let info { InfoButton(info) }
            Spacer(minLength: 4)
            control().labelsHidden().frame(maxWidth: 260, alignment: .trailing)
        }
    }

    /// The picture, layers and live test in their own scrolling pane.
    func picturePane(width: CGFloat) -> some View {
        ScrollView {
            // The inset keeps content clear of the pane's rounded edge and of its scroll bar.
            left(max(240, width - 36)).padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 12)
        }
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .frame(width: width)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.16), lineWidth: 1))
    }

    func left(_ width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceRow("Input controller", info: inputSource == .steamUSB
                      ? "Experimental USB cable / wireless receiver source for the 2015 Steam Controller. One active controller is selected automatically; plug the cable in before selecting the source to prefer USB.\n\nWhile this source is being read, Nokcandu turns off the controller’s built-in desktop mouse and keyboard controls and turns on motion reporting. Its original mode is restored on normal release; another app’s changed mode is preserved. Wireless recovery checks the remote controller’s identity before restoring its mode, even after reconnecting.\n\nClick either trackpad to choose its behavior independently: existing mappings, trackpad mouse or trackball mouse. Grips and pad clicks can be mapped separately.\n\nThe controller’s built-in button actions (a trigger as a mouse click, A as Return and so on) are switched off too, so only what this profile maps reaches the Mac or the game; they return when Nokcandu releases the controller. No pairing or firmware change is performed."
                      : "Automatic uses the controllers macOS recognizes. Choose Steam Controller for the original 2015 controller on its cable or wireless receiver.") {
                Picker("Input controller", selection: Binding(get: { inputSource }, set: { profile.controllerSource = $0 })) {
                    Text("Automatic (macOS controllers)").tag(PadProfiles.ControllerSource.automatic)
                    Text("Steam Controller (2015 · USB / receiver)").tag(PadProfiles.ControllerSource.steamUSB)
                }
            }
            sourceRow("Routing", info: "Native devices remain visible on macOS. Button suppression applies only through Nokcandu’s Wine mapping path. Select a stick, trigger or gyro to route it individually. Hybrid buttons can cause duplicate actions. Wine profiles use the existing Xbox-style controller path; Native input values does not promise the original device identity.") {
                Picker("Routing", selection: Binding(get: { effectiveRouting }, set: { profile.routingMode = $0 })) {
                    Text("Existing behavior").tag(PadProfiles.RoutingMode.legacy)
                    Text("Native input values").tag(PadProfiles.RoutingMode.native)
                    Text("Hybrid primary inputs").tag(PadProfiles.RoutingMode.hybridAll)
                    Text("Mapped primary inputs only").tag(PadProfiles.RoutingMode.remappingAll)
                    Text("Hybrid buttons").tag(PadProfiles.RoutingMode.hybrid)
                    Text("Mapped buttons only").tag(PadProfiles.RoutingMode.remapping)
                    Text("Selective inputs").tag(PadProfiles.RoutingMode.selective)
                }
            }
            if effectiveRouting == .selective, case .input(let input) = selection, PadProfiles.Input.padButtons.contains(input) {
                sourceRow("\(input.title(family)) routing") {
                    Picker("\(input.title(family)) routing", selection: Binding(get: { profile.buttonRoutes?[input.rawValue] ?? .mapped }, set: { route in
                        if profile.buttonRoutes == nil { profile.buttonRoutes = [:] }; profile.buttonRoutes?[input.rawValue] = route
                    })) {
                        ForEach(PadProfiles.ButtonRoute.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
            }
            if effectiveRouting == .selective {
                ForEach(selectedControlRoutes, id: \.self) { control in
                    sourceRow(Self.routeTitles[control, default: control.capitalized] + " routing",
                              info: "Native gyro and tilt delivery through Wine is unverified. Touch routing covers finger movement; touchpad clicks keep their button setting. Native routing leaves macOS device visibility unchanged; it does not create a gyro or virtual gamepad for the target.") {
                        Picker(Self.routeTitles[control, default: control.capitalized] + " routing", selection: Binding(get: { profile.controlRoutes?[control] }, set: { route in
                            if profile.controlRoutes == nil { profile.controlRoutes = [:] }; profile.controlRoutes?[control] = route
                        })) {
                            Text("Existing settings").tag(Optional<PadProfiles.ButtonRoute>.none)
                            ForEach(PadProfiles.ButtonRoute.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }
                    }
                }
            }
            layerBar
            DeviceStrip(mainTitle: inputSource == .steamUSB ? "Steam Controller" : "Controller", devices: devicesBinding, hasHead: headSourceBinding, shown: $shownDevice, selection: $selection)
            if selection == .headMotion {
                VStack(spacing: 12) {
                    Image(systemName: "airpodspro").font(.system(size: 68))
                    Text("AirPods / Headphones").font(.headline)
                    Text("Head motion → " + headSettingsBinding.wrappedValue.output.title).foregroundStyle(.secondary)
                    Text("A separate input source in this profile. Compatible headphones are selected by macOS.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(width: width, height: 230)
            } else if let id = shownDevice, let i = devicesBinding.wrappedValue.firstIndex(where: { $0.id == id }) {
                DevicePanel(device: devicesBinding[i], tester: tester, family: family, selection: $selection,
                            mapped: { k in let key = "dev.\(id).\(k)"; return profile.layers[layerIndex][key: key] != nil || inheritedDevice(key) != nil },
                            label: { k in let key = "dev.\(id).\(k)"; return shortLabel(profile.layers[layerIndex][key: key] ?? inheritedDevice(key)) },
                            remove: { removeDevice(id) })
                    .frame(width: width)
            } else {
                ControllerPicture(family: family, selection: $selection, tester: tester,
                                  mapped: { i in profile.layers[layerIndex][i] != nil || inherited(i) != nil },
                                  label: { i in shortLabel(i) }, stickLabel: { s in stickLabel(s) })
                    .frame(width: width, height: width * 400 / 560)
                ExtraButtons(tester: tester, family: family, selection: $selection,
                             mapped: { i in profile.layers[layerIndex][i] != nil || inherited(i) != nil })
            }
            PadTestView(tester: tester, family: family)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Devices

    var headSourceBinding: Binding<Bool> {
        Binding(get: { PadProfiles.headMotion(profile, all: everything)?.included == true }, set: { added in
            profile.headMotion = PadHeadMotionSettings(included: added, enabled: added)
            shownDevice = nil; selection = added ? .headMotion : .input(.a)
        })
    }
    var headSettingsBinding: Binding<PadHeadMotionSettings> {
        Binding(get: { PadProfiles.headMotion(profile, all: everything) ?? PadHeadMotionSettings() },
                set: { profile.headMotion = $0 })
    }

    /// The profile's devices (until it sets its own, the ones of the profile it builds on).
    var devicesBinding: Binding<[PadProfiles.Device]> {
        Binding(get: { profile.devices ?? PadProfiles.devices(profile, all: everything) },
                set: { profile.devices = $0.isEmpty && profile.buildsOn.isEmpty ? nil : $0 })
    }
    func inheritedDevice(_ k: String) -> PadProfiles.Binding? {
        let m = PadProfiles.deviceBindings(profile, all: everything)
        if let b = m[layerIndex == 0 ? "base" : layerName.lowercased()]?[k] { return b }
        guard layerIndex > 0 else { return nil }
        return profile.layers[0][key: k] ?? m["base"]?[k]
    }
    func removeDevice(_ id: String) {
        devicesBinding.wrappedValue.removeAll { $0.id == id }
        for l in profile.layers.indices { profile.layers[l].bindings = profile.layers[l].bindings.filter { !$0.key.hasPrefix("dev.\(id).") } }
        shownDevice = nil; selection = .input(.a)
    }
    func deviceBinding(_ k: String) -> Binding<PadProfiles.Binding?> {
        Binding(get: { profile.layers[layerIndex][key: k] }, set: { profile.layers[layerIndex][key: k] = $0 })
    }

    @ViewBuilder func deviceInputInspector(_ id: String, _ k: String) -> some View {
        if let d = devicesBinding.wrappedValue.first(where: { $0.id == id }) {
            let key = d.key(k)
            Section {
                BindingEditor(binding: deviceBinding(key), input: nil, family: family, layers: profile.layers.dropFirst().map(\.name),
                              inLayer: layerIndex > 0, inherited: profile.layers[layerIndex][key: key] == nil ? inheritedDevice(key).map(describe) : nil,
                              sameTitle: d.isGamepad && d.joined == true ? "As the controller's" : "As it is")
            } header: {
                InspectorTitle(title: d.inputTitle(k, family: family), subtitle: d.name + (layerIndex > 0 ? " · \(layerName) layer" : ""), symbol: "button.programmable")
            } footer: {
                Text(d.isGamepad && d.joined == true
                     ? "Left as it is, it does what the same button on the main controller does."
                     : "Left as it is, Windows games get it from the device itself, as usual. Set it to something here and they get that instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func deviceAxisInspector(_ id: String, _ n: Int) -> some View {
        if let i = devicesBinding.wrappedValue.firstIndex(where: { $0.id == id }) {
            let d = devicesBinding.wrappedValue[i]
            let a = Binding<PadProfiles.DeviceAxis>(get: { devicesBinding.wrappedValue[i].axis(n) },
                                                   set: { v in var list = devicesBinding.wrappedValue; list[i].setAxis(n, v); devicesBinding.wrappedValue = list })
            Section {
                Picker("Moves", selection: a.mode) { ForEach(PadProfiles.AxisMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                switch a.wrappedValue.mode {
                case .stick:
                    Picker("Which", selection: Binding(get: { a.wrappedValue.target ?? .lx }, set: { var v = a.wrappedValue; v.target = $0; a.wrappedValue = v })) {
                        ForEach(PadProfiles.AxisTarget.allCases, id: \.self) { Text($0.title(family)).tag($0) }
                    }
                case .mouse:
                    Picker("Direction", selection: Binding(get: { a.wrappedValue.vertical == true }, set: { var v = a.wrappedValue; v.vertical = $0 ? true : nil; a.wrappedValue = v })) {
                        Text("Left and right").tag(false); Text("Up and down").tag(true)
                    }
                    slider("Speed", Binding(get: { a.wrappedValue.speed ?? 1500 }, set: { var v = a.wrappedValue; v.speed = $0; a.wrappedValue = v }), 100...6000, "%.0f /s")
                    slider("Curve", Binding(get: { a.wrappedValue.curve ?? 1.5 }, set: { var v = a.wrappedValue; v.curve = $0; a.wrappedValue = v }), 0.5...4, "%.2f",
                           info: "1 is straight; higher starts slower for fine control and still reaches full speed.")
                case .off: EmptyView()
                }
            } header: {
                InspectorTitle(title: d.axisTitle(n, family: family), subtitle: d.name, symbol: "slider.horizontal.3")
            } footer: {
                if a.wrappedValue.mode == .stick {
                    Text("Several axes can move the same stick or trigger: they add up — two pedals as one rudder (one of them inverted), for example.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if a.wrappedValue.mode == .off && !(d.isGamepad && d.joined == true) {
                    Text("Windows games still get this axis from the device itself unless it's set to something.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Response") {
                Toggle("Rests at one end (a pedal or throttle)", isOn: Binding(get: { a.wrappedValue.restsAtEnd == true }, set: { var v = a.wrappedValue; v.restsAtEnd = $0 ? true : nil; a.wrappedValue = v }))
                Toggle("Invert", isOn: Binding(get: { a.wrappedValue.invert == true }, set: { var v = a.wrappedValue; v.invert = $0 ? true : nil; a.wrappedValue = v }))
                slider("Dead zone", Binding(get: { a.wrappedValue.deadzone ?? 0.05 }, set: { var v = a.wrappedValue; v.deadzone = $0; a.wrappedValue = v }), 0...0.5, "%.2f",
                       info: "How far it moves before it counts. Raise it if it drifts.")
                slider("Pressed at", Binding(get: { a.wrappedValue.pressAt ?? 0.5 }, set: { var v = a.wrappedValue; v.pressAt = $0; a.wrappedValue = v }), 0.1...0.95, "%.0f%%", scale: 100,
                       info: "How far it's pushed to count as the button press below.")
            }
            ForEach(a.wrappedValue.restsAtEnd == true || (d.isGamepad && n >= 4) ? ["a\(n)p"] : ["a\(n)p", "a\(n)n"], id: \.self) { k in
                Section(d.inputTitle(k, family: family)) {
                    BindingEditor(binding: deviceBinding(d.key(k)), input: nil, family: family, layers: profile.layers.dropFirst().map(\.name),
                                  inLayer: layerIndex > 0, inherited: profile.layers[layerIndex][key: d.key(k)] == nil ? inheritedDevice(d.key(k)).map(describe) : nil,
                                  sameTitle: "Nothing")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // The picture shrinks to leave the settings their room.
            GeometryReader { geo in
                if geo.size.width >= 880 {
                    HStack(alignment: .top, spacing: 16) {
                        picturePane(width: min(560, geo.size.width - 416))
                        Form { inspector }.formStyle(.grouped).frame(minWidth: 380, maxWidth: .infinity)
                    }
                } else {
                    // Too narrow for both side by side at a usable size: the picture above its settings.
                    VStack(spacing: 12) {
                        picturePane(width: geo.size.width).frame(height: max(200, geo.size.height * 0.5))
                        Form { inspector }.formStyle(.grouped)
                    }
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
        .frame(minWidth: embedded ? 420 : 1020, minHeight: embedded ? 500 : 720)
        .onAppear {
            family = PadProfiles.controllerLabelFamily(profile, all: everything, connected: PadGC.connectedFamily())
            tester.selectSource(inputSource)
            tester.configureSteamPads(left: PadProfiles.steamTrackpad(0, profile: profile, all: everything), right: PadProfiles.steamTrackpad(1, profile: profile, all: everything))
            tester.start(profile: PadProfiles.compile(profile, all: everything), devices: PadProfiles.devices(profile, all: everything))
        }
        .onDisappear {
            PadProfileEdits.shared.flush(PadProfileEdits.scope(profileID: profile.id, contents: own ? editingContents : nil))
            tester.stop()
        }
        .environment(\.padExtras, PadExtras(macros: PadProfiles.collected(profile, all: everything, \.macros).map { ($0.id, $0.name) },
                                              menus: PadProfiles.collected(profile, all: everything, \.menus).map { ($0.id, $0.name) }))
        .onChange(of: profile) { old, p in
            // Undo: one step per burst of changes (dragging a slider is one change).
            if !undoing {
                let t = ProcessInfo.processInfo.systemUptime
                if t - lastUndoPush > 0.8 { undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = [] }
                lastUndoPush = t
            }
            undoing = false
            PadProfileEdits.shared.submit(p, contents: own ? editingContents : nil, persist: onChange)
            tester.selectSource(inputSource)
            tester.configureSteamPads(left: PadProfiles.steamTrackpad(0, profile: p, all: everything), right: PadProfiles.steamTrackpad(1, profile: p, all: everything))
            family = PadProfiles.controllerLabelFamily(p, all: everything, connected: PadGC.connectedFamily())
            tester.reload(PadProfiles.compile(p, all: everything), devices: PadProfiles.devices(p, all: all.filter { $0.id != p.id } + [p]))
        }
        .sheet(isPresented: Binding(get: { addingLayer || renamingLayer }, set: { if !$0 { addingLayer = false; renamingLayer = false } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renamingLayer ? "Rename Layer" : "New Layer").font(.headline)
                Text(renamingLayer ? "Buttons that switch to it follow the new name." : "Give a button this layer while held, or switch it on/off, in the base layer to reach it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LayerNameField(text: $newLayerName) { finishLayer() }
                    .frame(height: 24)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { addingLayer = false; renamingLayer = false }
                        .keyboardShortcut(.cancelAction)
                    Button(renamingLayer ? "Rename" : "Add") { finishLayer() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newLayerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24).frame(width: 400)
        }
    }

    // MARK: Header and layers

    var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { headerTitle; Spacer(minLength: 0); headerControls }
            VStack(alignment: .leading, spacing: 8) {
                headerTitle
                HStack(spacing: 12) { headerControls; Spacer(minLength: 0) }
            }
        }
    }

    @ViewBuilder var headerTitle: some View {
        if own {
            Text("\(gameName)'s Controller Profile").font(.title2.bold()).lineLimit(1)
        } else {
            TextField("Name", text: $profile.name).textFieldStyle(.plain).font(.title2.bold()).frame(minWidth: 160, maxWidth: 320)
        }
    }

    @ViewBuilder var headerControls: some View {
        ControlGroup {
            Button { guard let last = undoStack.popLast() else { return }; redoStack.append(profile); undoing = true; profile = last } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty).keyboardShortcut("z", modifiers: .command).help("Undo")
            Button { guard let next = redoStack.popLast() else { return }; undoStack.append(profile); undoing = true; profile = next } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
        }
        .fixedSize()
        Picker("Labels", selection: Binding(get: { family }, set: { family = $0; profile.controllerLabels = $0?.rawValue ?? "xbox" })) {
            Text("Xbox").tag(Controllers.Family?.none)
            Text("PlayStation").tag(Controllers.Family?.some(.playstation))
            Text("Nintendo").tag(Controllers.Family?.some(.nintendo))
            Text("Steam").tag(Controllers.Family?.some(.valve))
        }.fixedSize().help("Button names and diagram style for this profile only. Other profiles keep their own choice.")
        buildsOnMenu
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
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layer", selection: $layerIndex) {
                ForEach(profile.layers.indices, id: \.self) { i in Text(i == 0 ? "Base" : profile.layers[i].name).tag(i) }
            }
            .pickerStyle(.segmented).frame(maxWidth: .infinity)
            FlowRow(spacing: 8) {
            Button { newLayerName = ""; addingLayer = true } label: { Image(systemName: "plus") }
                .help("Add a layer").disabled(profile.layers.count >= 8)
            Menu("Import Layer") {
                ForEach(all.filter { $0.id != profile.id }) { source in
                    Menu(source.name) {
                        ForEach(source.layers) { layer in
                            Button(layer.name) {
                                do {
                                    profile = try PadProfiles.importingLayer(from: source, layerID: layer.id, into: profile, all: everything)
                                    layerIndex = profile.layers.count - 1
                                } catch { layerImportError = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .fixedSize().disabled(profile.layers.count >= 8 || all.allSatisfy { $0.id == profile.id })
            .help("Copy another profile's layer settings and its macros and radial menus. Inherited base settings stay with their original profile.")
            .alert("Couldn’t Import Layer", isPresented: Binding(get: { layerImportError != nil }, set: { if !$0 { layerImportError = nil } })) {
                Button("OK", role: .cancel) { layerImportError = nil }
            } message: { Text(layerImportError ?? "") }
            if layerIndex > 0 {
                Menu {
                    Button("Rename…") { newLayerName = profile.layers[layerIndex].name; renamingLayer = true }
                    Button("Remove Layer", role: .destructive) { removeLayer() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
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
    }

    func swapped(_ a: PadProfiles.Input, _ b: PadProfiles.Input) -> Bool {
        profile.layers[layerIndex][a]?.press == [.pad(b)] && profile.layers[layerIndex][b]?.press == [.pad(a)]
    }
    func swap(_ a: PadProfiles.Input, _ b: PadProfiles.Input) {
        if swapped(a, b) { profile.layers[layerIndex][a] = nil; profile.layers[layerIndex][b] = nil }
        else { profile.layers[layerIndex][a] = .as(.pad(b)); profile.layers[layerIndex][b] = .as(.pad(a)) }
    }

    func finishLayer() {
        // Default-button and text-field submission can share the same event.
        guard addingLayer || renamingLayer else { return }
        let n = newLayerName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if var head = PadProfiles.headMotion(profile, all: everything), head.activationLayer.caseInsensitiveCompare(old) == .orderedSame {
            head.activationLayer = new ?? ""; profile.headMotion = head
        }
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

    /// What a stick does, short enough for the picture (nil: it's a stick, as it is).
    func stickLabel(_ s: Int) -> String? {
        if inputSource == .steamUSB && s == 1 {
            let mode = steamTrackpadBinding(1).wrappedValue.mode
            if mode != .existing { return mode == .trackball ? "Trackball" : "Trackpad mouse" }
        }
        let st = layerStick(s) ?? baseStick(s)
        switch st.mode {
        case .stick: return nil
        case .otherStick: return s == 0 ? "R stick" : "L stick"
        case .mouse: return "Mouse"
        case .flick: return "Flick"
        case .scroll: return "Scroll"
        case .off: return "Off"
        case .keys: return Self.keyRow(st.keys.map { PadProfiles.keyTitle($0) })
        case .directions:
            let parts = PadProfiles.Input.stickDirections(s).map { shortLabel($0) ?? "·" }
            return parts.allSatisfy { $0 == "·" } ? "Directions" : Self.keyRow(parts)
        }
    }
    /// Up, down, left, right as one short label: "WSAD", "Arrows", or "W S A D".
    static func keyRow(_ t: [String]) -> String {
        if t == ["Up Arrow", "Down Arrow", "Left Arrow", "Right Arrow"] || t == ["↑", "↓", "←", "→"] { return "Arrows" }
        let short = t.map { $0.replacingOccurrences(of: " Arrow", with: "").replacingOccurrences(of: "Left ", with: "L").replacingOccurrences(of: "Right ", with: "R") }
        // Single keys read like WASD: up, left, down, right.
        return short.allSatisfy { $0.count == 1 } ? [0, 2, 1, 3].map { short[$0] }.joined() : short.map { String($0.prefix(4)) }.joined(separator: " ")
    }
    func shortLabel(_ i: PadProfiles.Input) -> String? { shortLabel(profile.layers[layerIndex][i] ?? inherited(i)) }
    func shortLabel(_ binding: PadProfiles.Binding?) -> String? {
        guard let b = binding else { return nil }
        let first = b.pressOutputs.first ?? b.tap.first ?? b.hold.first ?? b.togetherOutputs.first
        guard let o = first else { return nil }
        switch o {
        case .keyToggle, .mouseToggle, .padToggle, .triggerToggle: return o.title(family)
        case .key(let k): return PadProfiles.keyTitle(k).replacingOccurrences(of: "Left ", with: "L").replacingOccurrences(of: "Right ", with: "R")
        case .mouse(let m): return m == .left ? "LMB" : m == .right ? "RMB" : m == .middle ? "MMB" : m == .back ? "M4" : "M5"
        case .pad(let p): return p.title(family)
        case .trigger(let r): return r ? "RT" : "LT"
        case .wheel(let up): return up ? "Wh↑" : "Wh↓"
        case .gyroOn, .gyroOff, .gyroToggle: return "Gyro"
        case .layerHold(let n), .layerToggle(let n): return String(n.prefix(4))
        case .macro: return "Macro"
        case .menu: return "Menu"
        case .keyboard: return "Kbd"
        case .calibrate: return "Calib"
        case .rumble: return "Rumble"
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
        case .deviceInput(let id, let k): deviceInputInspector(id, k)
        case .deviceAxis(let id, let n): deviceAxisInspector(id, n)
        case .touchpad: touchpadInspector
        case .tilt: tiltInspector
        case .macros: macrosInspector
        case .sequences: sequencesInspector
        case .menus: menusInspector
        case .feedback: feedbackInspector
        case .headMotion:
            PadHeadProfileSettings(settings: headSettingsBinding, profileID: profile.id, layers: merged.layers.map(\.name), family: family,
                remove: { headSourceBinding.wrappedValue = false }, editStick: { selection = .stick($0) })
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

    /// The layer's own stick settings, when it has them.
    func layerStick(_ s: Int) -> PadProfiles.Stick? {
        guard layerIndex > 0 else { return nil }
        let l = profile.layers[layerIndex]
        return (s == 0 ? l.leftStick : l.rightStick) ?? PadProfiles.layerSettings(profile, all: everything)[layerName.lowercased()].flatMap { s == 0 ? $0.left : $0.right }
    }
    func baseStick(_ s: Int) -> PadProfiles.Stick { (s == 0 ? profile.leftStick : profile.rightStick) ?? (s == 0 ? merged.left : merged.right) }
    func stickBinding(_ s: Int) -> Binding<PadProfiles.Stick> {
        if let own = layerStick(s) {
            return Binding(get: { layerStick(s) ?? own }, set: { if s == 0 { profile.layers[layerIndex].leftStick = $0 } else { profile.layers[layerIndex].rightStick = $0 } })
        }
        return Binding(get: { baseStick(s) }, set: { if s == 0 { profile.leftStick = $0 } else { profile.rightStick = $0 } })
    }
    @ViewBuilder func layerOwnToggle(_ title: String, has: Bool, set: @escaping (Bool) -> Void) -> some View {
        if layerIndex > 0 {
            Section {
                Toggle(title, isOn: Binding(get: { has }, set: set))
            } footer: {
                Text(has ? "While \(layerName) is on, these settings apply instead of the base layer's." : "Off: the same as the base layer.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func stickInspector(_ s: Int) -> some View {
        if inputSource == .steamUSB && s == 1 { steamTrackpadInspector(1) }
        else { joystickInspector(s) }
    }
    @ViewBuilder func joystickInspector(_ s: Int) -> some View {
        let st = stickBinding(s)
        layerOwnToggle("Own stick settings in \(layerName)", has: layerStick(s) != nil) { on in
            let v: PadProfiles.Stick? = on ? baseStick(s) : nil
            if s == 0 { profile.layers[layerIndex].leftStick = v } else { profile.layers[layerIndex].rightStick = v }
        }
        Section {
            Picker("Works as", selection: Binding(get: { st.wrappedValue.mode }, set: { m in
                // Four directions start from the keys it had, so switching over keeps what worked.
                if m == .directions, st.wrappedValue.mode == .keys {
                    for (d, k) in zip(PadProfiles.Input.stickDirections(s), st.wrappedValue.keys) where profile.layers[layerIndex][d] == nil {
                        profile.layers[layerIndex][d] = .as(.key(k))
                    }
                }
                var v = st.wrappedValue; v.mode = m; st.wrappedValue = v
            })) { ForEach(PadProfiles.StickMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            switch st.wrappedValue.mode {
            case .mouse:
                slider("Speed", st.speed, 200...6000, "%.0f /s")
                axisSliders(x: Binding(get: { st.wrappedValue.xScale ?? 1 }, set: { var v = st.wrappedValue; v.xScale = $0 == 1 ? nil : $0; st.wrappedValue = v }),
                            y: Binding(get: { st.wrappedValue.yScale ?? 1 }, set: { var v = st.wrappedValue; v.yScale = $0 == 1 ? nil : $0; st.wrappedValue = v }))
            case .flick:
                slider("One full turn", st.countsPerTurn, 500...20000, "%.0f", info: "Mouse movement that turns the game's camera all the way round. Flick the stick right: it should turn exactly 90°.")
                slider("Flick time", st.flickTime, 0...0.3, "%.2f s")
            case .scroll:
                slider("Speed", Binding(get: { st.wrappedValue.scrollSpeed ?? 20 }, set: { var v = st.wrappedValue; v.scrollSpeed = $0; st.wrappedValue = v }), 2...80, "%.0f lines/s")
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
            InspectorTitle(title: s == 0 ? "Left Stick" : inputSource == .steamUSB ? "Right Trackpad (as stick)" : "Right Stick", subtitle: nil, symbol: s == 0 ? "l.joystick" : "r.joystick")
        } footer: {
            if st.wrappedValue.mode == .flick {
                Text("Push the stick to the edge to turn to face that way; rotate it around the edge to keep turning. Pairs well with gyro aim.").font(.caption).foregroundStyle(.secondary)
            } else if st.wrappedValue.mode == .directions {
                Text("Each direction works like a button: a key, a mouse button, a controller button, tap and hold, layers… Diagonals press both.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if st.wrappedValue.mode == .directions {
            ForEach(PadProfiles.Input.stickDirections(s), id: \.self) { d in
                Section(["Up", "Down", "Left", "Right"][PadProfiles.Input.stickDirections(s).firstIndex(of: d) ?? 0]) {
                    BindingEditor(binding: bindingFor(d), input: d, family: family, layers: profile.layers.dropFirst().map(\.name),
                                  inLayer: layerIndex > 0, inherited: profile.layers[layerIndex][d] == nil ? inherited(d).map(describe) : nil, sameTitle: "Nothing")
                }
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

    var layerGyro: PadProfiles.Gyro? {
        guard layerIndex > 0 else { return nil }
        return profile.layers[layerIndex].gyro ?? PadProfiles.layerSettings(profile, all: everything)[layerName.lowercased()]?.gyro
    }
    var gyroBinding: Binding<PadProfiles.Gyro> {
        if let own = layerGyro { return Binding(get: { layerGyro ?? own }, set: { profile.layers[layerIndex].gyro = $0 }) }
        return Binding(get: { profile.gyro ?? merged.gyro }, set: { profile.gyro = $0 })
    }

    @ViewBuilder var gyroInspector: some View {
        let g = gyroBinding
        layerOwnToggle("Own gyro settings in \(layerName)", has: layerGyro != nil) { on in
            profile.layers[layerIndex].gyro = on ? (profile.gyro ?? merged.gyro) : nil
        }
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
                Toggle("Calibrate when the controller is put down", isOn: g.autoCalibrate)
            }
            Section {
                Toggle("Smart smoothing (One Euro filter)", isOn: Binding(get: { g.wrappedValue.filter == true }, set: { var v = g.wrappedValue; v.filter = $0 ? true : nil; g.wrappedValue = v }))
                if g.wrappedValue.filter == true {
                    slider("Steadiness", Binding(get: { 20 - (g.wrappedValue.filterMinCutoff ?? 5) }, set: { var v = g.wrappedValue; v.filterMinCutoff = max(0.3, 20 - $0); g.wrappedValue = v }), 0...19.7, "%.1f",
                           info: "How much slow, careful aiming is smoothed. Higher is steadier.")
                    slider("Quick when fast", Binding(get: { g.wrappedValue.filterBeta ?? 0.05 }, set: { var v = g.wrappedValue; v.filterBeta = $0; g.wrappedValue = v }), 0...0.5, "%.2f",
                           info: "How quickly smoothing gets out of the way as you turn faster, so flicks don't lag.")
                }
            } header: { Text("Filter") } footer: {
                Text("Smooths slow movement a lot and fast movement hardly at all — steady aim without lag. Calibrate any time with a button set to “Calibrate the gyro”, or a keyboard shortcut in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
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
    /// The controller's button being set (nil: a device's).
    let input: PadProfiles.Input?
    let family: Controllers.Family?
    let layers: [String]
    let inLayer: Bool
    var inherited: String? = nil
    /// What "leave it" is called outside a layer.
    var sameTitle = "Itself"
    @State private var more = false

    enum Kind: String, CaseIterable { case same, press, toggle, taps }
    var kind: Kind {
        guard let b = binding, !(b.press.isEmpty && b.tap.isEmpty && b.hold.isEmpty && b.double.isEmpty) else { return .same }
        if !b.tap.isEmpty || !b.hold.isEmpty || !b.double.isEmpty { return .taps }
        return b.togglesOnPress ? .toggle : .press
    }

    var body: some View {
        Picker("Does", selection: Binding(get: { kind }, set: setKind)) {
            Text(inLayer ? "Inherited" : sameTitle).tag(Kind.same)
            Text("While held").tag(Kind.press)
            Text("Toggle").tag(Kind.toggle)
            Text("Tap / Hold").tag(Kind.taps)
        }
        .pickerStyle(.segmented)
        if kind == .same, let inherited {
            LabeledContent(inLayer ? "Inherited action" : "Inherited from parent profile") { Text(inherited).foregroundStyle(.secondary) }
        }
        if let b = binding {
            switch kind {
            case .press:
                OutputsEditor(title: "Press", outputs: field(\.press), family: family, layers: layers)
                Toggle("Repeat while held", isOn: Binding(get: { (b.turbo ?? 0) > 0 }, set: { binding?.turbo = $0 ? 100 : nil }))
                if let t = b.turbo, t > 0 {
                    LabeledContent("Every") { Stepper("\(t) ms", value: Binding(get: { t }, set: { binding?.turbo = $0 }), in: 30...1000, step: 10) }
                }
            case .toggle:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Press once to keep the selected output held. Press again to release it. Turning the profile off releases it too.")
                        .font(.caption).foregroundStyle(.secondary)
                    OutputsEditor(title: "Toggle", outputs: field(\.press), family: family, layers: layers, toggled: true)
                    Text("Keys and mouse buttons work on the Mac. Controller buttons and triggers are output through Nokcandu's Windows-game controller route.")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .contain)
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
        Binding(get: { binding?[keyPath: k] ?? [] }, set: { v in
            var b = binding ?? PadProfiles.Binding()
            b[keyPath: k] = k == \.press && b.togglePress == true ? v.compactMap(\.toggledOutput) : v
            binding = b
        })
    }

    func setKind(_ k: Kind) {
        switch k {
        case .same:
            if let t = binding?.together, let o = binding?.togetherOutputs, !o.isEmpty { binding = PadProfiles.Binding(together: t, togetherOutputs: o) }
            else { binding = nil }
        case .toggle:
            var b = binding ?? PadProfiles.Binding()
            let source = b.press.isEmpty ? b.tap : b.press
            b.press = source.compactMap(\.toggledOutput)
            if b.press.isEmpty { b.press = [.nothing] }
            b.togglePress = true; b.turbo = nil
            b.tap = []; b.hold = []; b.double = []
            binding = b
        case .press:
            var b = binding ?? PadProfiles.Binding()
            b.togglePress = nil; b.press = b.press.map(\.heldOutput)
            if b.press.isEmpty { b.press = b.tap.isEmpty ? [.nothing] : b.tap }
            b.tap = []; b.hold = []; b.double = []
            binding = b
        case .taps:
            var b = binding ?? PadProfiles.Binding()
            b.togglePress = nil; b.press = b.press.map(\.heldOutput)
            if b.tap.isEmpty { b.tap = b.press.isEmpty ? (input.map { $0.isTrigger || $0.isStickDirection ? [.nothing] : [.pad($0)] } ?? [.nothing]) : b.press }
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
    var toggled = false
    @State private var recording = false
    @State private var monitor: Any?
    @State private var recorder = PadOutputRecorder()
    @Environment(\.padExtras) var extras

    func add(_ selected: PadProfiles.Output) {
        guard let o = toggled ? selected.toggledOutput : selected else { return }
        if o == .nothing { outputs = [.nothing] } else { outputs.removeAll { $0 == .nothing }; if !outputs.contains(o) { outputs.append(o) } }
    }

    /// The next key, mouse button or scroll becomes an output. Modifiers held with a key are added too (Shift+R).
    func record() {
        recording = true; recorder.reset()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { e in
            let input: PadOutputRecorder.Input
            switch e.type {
            case .flagsChanged:
                let k = Int(e.keyCode)
                let down: Bool
                switch k {
                case 56, 60: down = e.modifierFlags.contains(.shift)
                case 59, 62: down = e.modifierFlags.contains(.control)
                case 58, 61: down = e.modifierFlags.contains(.option)
                case 55, 54: down = e.modifierFlags.contains(.command)
                case 63: down = e.modifierFlags.contains(.function)
                case 57: down = true
                default: return e
                }
                input = .modifier(k, down: down)
            case .keyDown: input = .key(Int(e.keyCode))
            case .leftMouseDown: input = .mouseButton(0)
            case .rightMouseDown: input = .mouseButton(1)
            case .otherMouseDown: input = .mouseButton(e.buttonNumber)
            case .scrollWheel: input = .wheel(Double(e.scrollingDeltaY))
            default: return e
            }
            switch recorder.receive(input) {
            case .waiting: break
            case .cancelled: stopRecording()
            case .outputs(let values):
                for value in values { add(value) }
                stopRecording()
            }
            return nil
        }
    }
    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; recording = false; recorder.reset()
    }

    var body: some View {
        LabeledContent(title) {
            FlowRow {
                ForEach(Array(outputs.enumerated()), id: \.offset) { i, o in
                    HStack(spacing: 3) {
                        Text(extras.title(o, family)).font(.callout)
                        Button { outputs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(o.title(family))")
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Menu(outputs.isEmpty ? "Choose" : "Add") { OutputMenu(family: family, layers: layers, heldOnly: toggled) { o in add(o) } }
                    .fixedSize()
                Button(recording ? "Press a key or click… (Esc cancels)" : "Record…") { recording ? stopRecording() : record() }
                    .help("Press a key, or click or scroll the mouse inside this window, to add it. Escape cancels. Choose Escape from the Key menu when you want to map it.")
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
            }
        }
        .onDisappear { stopRecording() }
    }
}

struct OutputMenu: View {
    let family: Controllers.Family?
    let layers: [String]
    var heldOnly = false
    let pick: (PadProfiles.Output) -> Void
    @Environment(\.padExtras) var extras

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
        if !heldOnly {
        Menu("Toggle Held Key") {
            ForEach(keys) { k in Button(k.title) { pick(.keyToggle(k.code)) } }
        }
        Menu("Toggle Held Mouse Button") {
            ForEach(PadProfiles.MouseButton.allCases, id: \.self) { m in Button(m.title) { pick(.mouseToggle(m)) } }
        }
        }
        Menu("Mouse") {
            ForEach(PadProfiles.MouseButton.allCases, id: \.self) { m in Button(m.title) { pick(.mouse(m)) } }
            if !heldOnly {
                Button("Scroll up") { pick(.wheel(up: true)) }
                Button("Scroll down") { pick(.wheel(up: false)) }
            }
        }
        Menu("Controller") {
            ForEach(PadProfiles.Input.padButtons, id: \.self) { i in Button(i.title(family)) { pick(.pad(i)) } }
            Divider()
            Button(PadProfiles.Input.lt.title(family)) { pick(.trigger(right: false)) }
            Button(PadProfiles.Input.rt.title(family)) { pick(.trigger(right: true)) }
        }
        if !heldOnly {
        Menu("Gyro") {
            Button("Gyro on while held") { pick(.gyroOn) }
            Button("Gyro off while held") { pick(.gyroOff) }
            Button("Gyro on/off") { pick(.gyroToggle) }
            Divider()
            Button("Calibrate the gyro") { pick(.calibrate) }
        }
        Button("Rumble") { pick(.rumble) }
        if !extras.macros.isEmpty {
            Menu("Macro") { ForEach(extras.macros, id: \.0) { m in Button(m.1) { pick(.macro(m.0)) } } }
        }
        if !extras.menus.isEmpty {
            Menu("Radial menu") { ForEach(extras.menus, id: \.0) { m in Button(m.1 + " (while held)") { pick(.menu(m.0)) } } }
        }
        Button("On-screen keyboard") { pick(.keyboard) }
        if !layers.isEmpty {
            Menu("Layer") {
                ForEach(layers, id: \.self) { n in
                    Button("\(n) while held") { pick(.layerHold(n)) }
                    Button("\(n) on/off") { pick(.layerToggle(n)) }
                }
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
            ForEach(family == .valve ? [PadProfiles.Input.paddle1, .paddle2, .touchpad, .rs] : [PadProfiles.Input.paddle1, .paddle2, .paddle3, .paddle4, .touchpad, .misc], id: \.self) { i in
                Button { selection = .input(i) } label: {
                    Text(i.title(family)).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(tester.pressed.contains(i) ? Color.accentColor.opacity(0.6) : mapped(i) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selection == .input(i) ? Color.accentColor : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
            }
            Button { selection = .triggers } label: { Text("Trigger pull").font(.caption) }.buttonStyle(.link)
            ForEach([("Touchpad", ControllerProfileEditor.Part.touchpad), ("Tilt", .tilt), ("Macros", .macros), ("Sequences", .sequences),
                     ("Radial menus", .menus), ("Feedback", .feedback)], id: \.0) { t, part in
                Button { selection = part } label: { Text(t).font(.caption).fontWeight(selection == part ? .bold : .regular) }.buttonStyle(.link)
            }
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


// MARK: - Devices combined with the controller

/// The controller and the profile's other devices; pick one to show it, or add one that's connected.
struct DeviceStrip: View {
    var mainTitle = "Controller"
    @Binding var devices: [PadProfiles.Device]
    @Binding var hasHead: Bool
    @Binding var shown: String?
    @Binding var selection: ControllerProfileEditor.Part
    @ObservedObject var hid = HIDDevices.shared

    var addable: [HIDDevices.Info] { hid.connected.filter { i in !devices.contains { i.matches($0) } } }

    func chip(_ title: String, symbol: String, on: Bool, connected: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.callout).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                .opacity(connected ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        FlowRow(spacing: 6) {
            chip(mainTitle, symbol: "gamecontroller", on: shown == nil && selection != .headMotion) { shown = nil; selection = .input(.a) }
            ForEach(devices) { d in
                let connected = hid.connected.contains { $0.matches(d) }
                chip(d.name, symbol: d.isGamepad ? "gamecontroller" : "dial.medium", on: shown == d.id, connected: connected) {
                    shown = d.id; selection = .deviceInput(d.id, "b0")
                }
                .help(connected ? d.productName : "\(d.productName) — not connected")
            }
            if hasHead {
                chip("AirPods / Headphones", symbol: "airpodspro", on: selection == .headMotion) {
                    shown = nil; selection = .headMotion
                }
            }
            if devices.count < 4 || !hasHead {
                Menu {
                    if !hasHead {
                        Button("AirPods / Headphones (experimental)") { hasHead = true }
                        Divider()
                    }
                    if addable.isEmpty { Text("Connect a joystick, throttle, pedals, wheel or another controller") }
                    ForEach(devices.count < 4 ? addable : []) { i in
                        Button(i.name + (i.nth > 0 ? " (\(i.nth + 1))" : "")) {
                            var d = i.device
                            let same = devices.filter { $0.productName == d.productName }.count
                            if same > 0 { d.name += " \(same + 1)" }
                            devices.append(d); shown = d.id; selection = .deviceInput(d.id, "b0")
                        }
                    }
                } label: { Label("Add Device", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Combine a joystick, throttle, pedals, a wheel, a button box or another controller with this profile")
            }
        }
        .onAppear { hid.start() }
    }
}

/// One of the profile's devices: its buttons, hat and axes, lit up as you use them. Pressing or moving something
/// on the device selects it.
struct DevicePanel: View {
    @Binding var device: PadProfiles.Device
    @ObservedObject var tester: PadTester
    let family: Controllers.Family?
    @Binding var selection: ControllerProfileEditor.Part
    let mapped: (String) -> Bool
    let label: (String) -> String?
    let remove: () -> Void
    @ObservedObject var hid = HIDDevices.shared
    @State private var confirmRemove = false

    var connected: Bool { hid.connected.contains { $0.matches(device) } }

    func chip(_ k: String) -> some View {
        let held = tester.deviceHeld.contains(device.id + "." + k)
        let isSel = selection == .deviceInput(device.id, k)
        return Button { selection = .deviceInput(device.id, k) } label: {
            VStack(spacing: 1) {
                Text(device.inputTitle(k, family: family)).font(.caption).lineLimit(1)
                if let l = label(k), l != "—" { Text(l).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(held ? Color.accentColor.opacity(0.6) : mapped(k) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSel ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    func axisRow(_ n: Int) -> some View {
        let v = tester.deviceAxes[device.id + "." + String(n)] ?? 0
        let a = device.axis(n)
        let isSel = selection == .deviceAxis(device.id, n)
        let what: String = {
            switch a.mode {
            case .off: return mapped("a\(n)p") || mapped("a\(n)n") ? "Buttons" : (device.isGamepad && device.joined == true ? "As the controller's" : "As it is")
            case .stick: return (a.target ?? .lx).title(family)
            case .mouse: return a.vertical == true ? "Mouse up and down" : "Mouse left and right"
            }
        }()
        return Button { selection = .deviceAxis(device.id, n) } label: {
            HStack(spacing: 8) {
                Text(device.axisTitle(n, family: family)).font(.callout).frame(width: 120, alignment: .leading).lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.accentColor).frame(width: 4).offset(x: (CGFloat(v) + 1) / 2 * (g.size.width - 4))
                    }
                }
                .frame(height: 8)
                Text(what).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Name", text: $device.name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Text(connected ? device.productName : "\(device.productName) · not connected").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Remove", role: .destructive) { confirmRemove = true }
                }
                if device.isGamepad {
                    Toggle("Part of the main controller", isOn: Binding(get: { device.joined == true }, set: { device.joined = $0 ? true : nil }))
                    Text(device.joined == true
                         ? "Buttons and sticks you don't set here do what the main controller's do, and games see one controller — for two halves held in each hand, or two controllers for one player."
                         : "Only what you set here changes; games still see this controller on its own.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Buttons").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowRow(spacing: 5) { ForEach(0..<device.buttons, id: \.self) { n in chip("b\(n)") } }
                if device.hat {
                    Text("Hat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    FlowRow(spacing: 5) { ForEach(PadProfiles.Device.hatKeys, id: \.self) { k in chip(k) } }
                }
                if device.axisCount > 0 {
                    Text(device.isGamepad ? "Sticks and triggers" : "Axes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) { ForEach(0..<device.axisCount, id: \.self) { n in axisRow(n) } }
                }
                Text(connected ? "Press a button or move an axis on the device to select it." : "Connect it to test it and select things by pressing them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .onChange(of: tester.lastDeviceInput) { _, i in
            guard let i, i.device == device.id else { return }
            if i.key.hasPrefix("axis"), let n = Int(i.key.dropFirst(4)) { selection = .deviceAxis(device.id, n) }
            else { selection = .deviceInput(device.id, i.key) }
        }
        .confirmationDialog("Remove \(device.name) from this profile?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: remove)
        } message: { Text("What its buttons and axes were set to is removed too.") }
    }
}
