import SwiftUI
import NokcanduCore

extension ControllerProfileEditor {
    /// The layer's own pad settings, when it has them (its own, or from a profile underneath).
    func layerSteamPad(_ side: Int) -> PadSteamTrackpadSettings? {
        guard layerIndex > 0 else { return nil }
        return PadProfiles.layerSteamTrackpad(side, layer: layerName, profile: profile, all: everything)
    }
    func baseSteamPad(_ side: Int) -> PadSteamTrackpadSettings {
        (side == 0 ? PadProfiles.top(profile, all: everything, \.steamLeftTrackpad) : PadProfiles.top(profile, all: everything, \.steamRightTrackpad)) ?? PadSteamTrackpadSettings()
    }
    func steamTrackpadBinding(_ side: Int) -> Binding<PadSteamTrackpadSettings> {
        if let own = layerSteamPad(side) {
            return Binding(get: { layerSteamPad(side) ?? own }, set: { value in
                if side == 0 { profile.layers[layerIndex].steamLeftTrackpad = value } else { profile.layers[layerIndex].steamRightTrackpad = value }
            })
        }
        return Binding(get: { baseSteamPad(side) }, set: { value in
            if side == 0 { profile.steamLeftTrackpad = value } else { profile.steamRightTrackpad = value }
        })
    }
    @ViewBuilder func steamTrackpadInspector(_ side: Int) -> some View {
        let settings = steamTrackpadBinding(side)
        layerOwnToggle("Own pad settings in \(layerName)", has: layerSteamPad(side) != nil) { on in
            let value: PadSteamTrackpadSettings? = on ? baseSteamPad(side) : nil
            if side == 0 { profile.layers[layerIndex].steamLeftTrackpad = value } else { profile.layers[layerIndex].steamRightTrackpad = value }
        }
        Section {
            Picker("Pad behavior", selection: Binding(get: { settings.wrappedValue.mode }, set: { mode in
                settings.wrappedValue.mode = mode
                // A pad set to directions for the first time starts as the usual keys, ready to change.
                let directions = PadProfiles.Input.padDirections(side)
                if mode == .directions, directions.allSatisfy({ profile.layers[0][$0] == nil && profile.layers[layerIndex][$0] == nil && inherited($0) == nil }) {
                    for (input, key) in zip(directions, side == 0 ? [13, 1, 0, 2] : [126, 125, 123, 124]) { profile.layers[0][input] = .as(.key(key)) }
                }
            })) {
                Text(side == 0 ? "Existing touchpad settings" : "Joystick settings").tag(PadSteamTrackpadSettings.Mode.existing)
                Text("Trackpad mouse").tag(PadSteamTrackpadSettings.Mode.mouse)
                Text("Trackball mouse").tag(PadSteamTrackpadSettings.Mode.trackball)
                Text(side == 0 ? "Four directions (W A S D…)" : "Four directions (arrows…)").tag(PadSteamTrackpadSettings.Mode.directions)
                Text(side == 0 ? "Analog stick (left stick)" : "Analog stick (right stick)").tag(PadSteamTrackpadSettings.Mode.stick)
                Text("Scroll wheel (circle)").tag(PadSteamTrackpadSettings.Mode.dial)
            }
            Toggle("Touch haptics", isOn: Binding(get: { (settings.wrappedValue.touchFeedback ?? 0) > 0 }, set: { settings.wrappedValue.touchFeedback = $0 ? 0.2 : nil }))
                .help("One short pulse when your finger first touches this pad, even without moving. Independent of Movement haptics.")
            if (settings.wrappedValue.touchFeedback ?? 0) > 0 {
                slider("Touch strength", Binding(get: { settings.wrappedValue.touchFeedback ?? 0.2 }, set: { settings.wrappedValue.touchFeedback = $0 }), 0.05...1, "%.0f%%", scale: 100)
            }
            slider("Edge size", Binding(get: { PadSteamPadZones.edgeSize(settings.wrappedValue) }, set: { settings.wrappedValue.edge = $0 < 0.02 ? nil : $0 }), 0...0.5, "%.0f%%", scale: 100, info: "The outer part of the pad, shown as a ring on the picture, is an input of its own: it is held while your finger is there, whatever else the pad does. Give it Shift to sprint when you push to the rim, for example. 0 turns the edge off.")
            if settings.wrappedValue.mode == .dial {
                slider("Turn per step", Binding(get: { PadSteamDial.step(settings.wrappedValue) }, set: { settings.wrappedValue.dialStep = $0 }), 5...90, "%.0f°", info: "How far round the pad your thumb circles for each scroll step. Smaller is faster scrolling.")
                Toggle("Reverse direction", isOn: Binding(get: { settings.wrappedValue.dialReverse == true }, set: { settings.wrappedValue.dialReverse = $0 ? true : nil }))
                    .help("Normally circling clockwise scrolls down, like a scroll wheel turned towards you.")
                Toggle("Haptic tick per step", isOn: Binding(get: { (settings.wrappedValue.dialHaptic ?? 0) > 0 }, set: { settings.wrappedValue.dialHaptic = $0 ? 0.3 : nil }))
                if (settings.wrappedValue.dialHaptic ?? 0) > 0 {
                    slider("Tick strength", Binding(get: { settings.wrappedValue.dialHaptic ?? 0.3 }, set: { settings.wrappedValue.dialHaptic = $0 }), 0.05...1, "%.0f%%", scale: 100)
                }
                Text("Circle your thumb around the outer part of the pad to scroll, the way the Steam Controller was designed. The centre does nothing, so resting there is safe.").font(.caption).foregroundStyle(.secondary)
            }
            if settings.wrappedValue.mode == .stick {
                slider("Centre dead zone", Binding(get: { PadSteamPadStick.deadzone(settings.wrappedValue) }, set: { settings.wrappedValue.deadzone = $0 }), 0...0.6, "%.0f%%", scale: 100, info: "How far from the middle the stick starts to move. It reaches full push just inside the rim.")
                slider("Pad angle", Binding(get: { settings.wrappedValue.rotation ?? PadSteamTrackpadSettings.defaultRotation(side: side) }, set: { settings.wrappedValue.rotation = $0 }), -30...30, "%.0f°", info: "Turns the stick's directions to match your thumb's natural sweep.")
                Text(side == 0 ? "Works as the left stick, alongside the joystick: whichever is pushed further counts. Games see a real analog stick, so you can walk slowly and run." : "Works as the right stick with the dead zone and angle above.").font(.caption).foregroundStyle(.secondary)
            }
            if settings.wrappedValue.mode == .directions {
                slider("Centre dead zone", Binding(get: { PadSteamPadZones.deadzone(settings.wrappedValue) }, set: { settings.wrappedValue.deadzone = $0 }), 0.05...0.8, "%.0f%%", scale: 100, info: "How far from the middle of the pad a direction starts. Between two directions, both are held.")
                slider("Pad angle", Binding(get: { settings.wrappedValue.rotation ?? PadSteamTrackpadSettings.defaultRotation(side: side) }, set: { settings.wrappedValue.rotation = $0 }), -30...30, "%.0f°", info: "Turns the pad’s directions to match your thumb’s natural sweep. The picture shows the result.")
            }
            if settings.wrappedValue.mode.movesPointer {
                slider("X sensitivity", Binding(get: { settings.wrappedValue.sensitivityX ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityX = $0 }), 200...5000, "%.0f", info: "Horizontal movement across the whole pad.")
                slider("Y sensitivity", Binding(get: { settings.wrappedValue.sensitivityY ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityY = $0 }), 200...5000, "%.0f", info: "Vertical movement across the whole pad.")
                slider("Smoothing", Binding(get: { settings.wrappedValue.smoothing ?? PadSteamTrackpadSettings.defaultSmoothing }, set: { settings.wrappedValue.smoothing = $0 }), 0...1, "%.0f%%", scale: 100, info: "Steadies a resting or slow finger and steps aside as it speeds up, so quick movement stays immediate. 0 follows the pad’s raw readings. Try this before Small movement steadiness: it has no distance to push through when you change direction.")
                slider("Pad angle", Binding(get: { settings.wrappedValue.rotation ?? PadSteamTrackpadSettings.defaultRotation(side: side) }, set: { settings.wrappedValue.rotation = $0 }), -30...30, "%.0f°", info: "Turns the pad’s axes to match your thumb’s natural sweep, so a sideways swipe moves the pointer straight across. 0° uses the pad’s own directions; Valve's drivers use \(side == 0 ? "−15" : "15")° for this pad. If straight swipes come out slanted, try a few degrees either way.")
                // Superseded by Smoothing: shown only while an older profile still uses it.
                if (settings.wrappedValue.steadiness ?? 0) > 0, (PadProfiles.steamTrackpad(side, profile: profile, all: everything).smoothing ?? 0) == 0 { slider("Small movement steadiness", Binding(get: { settings.wrappedValue.steadiness ?? 0 }, set: { settings.wrappedValue.steadiness = $0 }), 0...5, "%.1f px", info: "Ignores tiny back-and-forth wobble on each axis. 0 follows raw motion. Higher values can steady slow aiming, but the pointer waits for that distance before it follows a change of direction, which can feel like resistance. Prefer Smoothing, and set this to 0 to retire it.") }
                Toggle("Invert up and down", isOn: settings.invertY)
                if settings.wrappedValue.mode == .trackball {
                    slider("Momentum half-life", settings.halfLife, 0.02...0.6, "%.2f s", info: "After a flick and lift, speed halves over this time. Touch the pad again to stop immediately.")
                }
                Toggle("Movement haptics", isOn: Binding(get: { (settings.wrappedValue.movementFeedback ?? 0) > 0 }, set: { settings.wrappedValue.movementFeedback = $0 ? 0.35 : nil }))
                if (settings.wrappedValue.movementFeedback ?? 0) > 0 {
                    slider("Haptic strength", Binding(get: { settings.wrappedValue.movementFeedback ?? 0.35 }, set: { settings.wrappedValue.movementFeedback = $0 }), 0.05...1, "%.0f%%", scale: 100)
                    Toggle("Match cursor movement", isOn: Binding(get: { settings.wrappedValue.hapticFollowsMovement ?? true }, set: { settings.wrappedValue.hapticFollowsMovement = $0 }))
                        .help("Pulse more often as this pad moves the cursor faster, including trackball coast. Turn off for a fixed repeat rate.")
                    slider("Pulse rate", Binding(get: { settings.wrappedValue.hapticRate ?? 40 }, set: { settings.wrappedValue.hapticRate = $0 }), 5...40, "%.0f /s", info: "Maximum bursts per second. With Match cursor movement on, slower cursor movement produces fewer bursts; faster movement reaches this limit.")
                    slider("Pulse spacing", Binding(get: { settings.wrappedValue.hapticSpacingMS ?? 1 }, set: { settings.wrappedValue.hapticSpacingMS = $0 }), 0.1...3, "%.1f ms", info: "Spacing between the three tiny pulses in each burst. Changes the texture independently of strength and repeat rate.")
                    SteamPadHapticTest(side: side, strength: settings.wrappedValue.movementFeedback ?? 0.35, rate: settings.wrappedValue.hapticRate ?? 40, spacingMS: settings.wrappedValue.hapticSpacingMS ?? 1)
                }
            }
            Toggle("Activate gyro while touching", isOn: Binding(get: { settings.wrappedValue.gyroWhileTouched == true }, set: { on in
                settings.wrappedValue.gyroWhileTouched = on ? true : nil
                if on && gyroBinding.wrappedValue.output == .off {
                    var gyro = gyroBinding.wrappedValue; gyro.output = .mouse; gyro.startsOn = false; gyroBinding.wrappedValue = gyro
                }
            }))
            Text("With touch activation selected on either pad, controller gyro works only while one of those pads is touched. Uses the Gyro settings; a held Gyro off button still overrides it.").font(.caption).foregroundStyle(.secondary)
            GyroNotificationToggle()
        } header: { Text(side == 0 ? "Left Trackpad" : "Right Trackpad") }
          footer: {
            Text("Each pad chooses its behavior independently, and a layer can have pad settings of its own. Trackpad mouse follows finger movement; trackball mouse continues after a flick and lift; four directions holds a key or button for each way you push; analog stick works as a real stick. Profile changes, focus changes and lost input cancel momentum.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if PadSteamPadZones.edgeSize(settings.wrappedValue) > 0 {
            Section {
                inputEditor(PadProfiles.Input.padEdge(side))
            } header: { Text("Pad Edge") } footer: {
                Text("Held while your finger is in the ring at the rim, together with whatever the pad is doing there.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            inputEditor(PadProfiles.Input.padTap(side))
        } header: { Text("Tap") } footer: {
            Text("A quick touch and lift without moving. Choose “Double” in its settings for a double tap. Taps work in every pad behavior.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Zones", selection: Binding(get: { settings.wrappedValue.zoneLayout ?? .off }, set: { settings.wrappedValue.zoneLayout = $0 == .off ? nil : $0 })) {
                ForEach(PadSteamZoneLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            let layout = settings.wrappedValue.zoneLayout ?? .off
            if layout != .off {
                Picker("Zone", selection: $padZoneShown) {
                    ForEach(Array(layout.names.enumerated()), id: \.offset) { n, name in Text(name).tag(n) }
                }
                .pickerStyle(.segmented)
                let n = min(padZoneShown, layout.names.count - 1)
                LabeledContent("Tap") { EmptyView() }
                inputEditor(PadProfiles.Input.padZoneTap(side, n))
                LabeledContent("Click") { EmptyView() }
                inputEditor(PadProfiles.Input.padZoneClick(side, n))
            }
        } header: { Text("Zones") } footer: {
            Text("Divide the pad so a tap, double tap or click in each part does something of its own, whatever the pad's behavior. A zone with nothing set uses the pad's ordinary tap or click. The zones turn with the pad angle and show on the picture.").font(.caption).foregroundStyle(.secondary)
        }
        if settings.wrappedValue.mode == .directions {
            ForEach(PadProfiles.Input.padDirections(side), id: \.self) { input in
                Section(input.title(family)) { inputEditor(input) }
            }
        }
        if settings.wrappedValue.mode == .existing {
            if side == 0 { legacyTouchpadInspector } else { joystickInspector(1) }
        } else {
            Section("Trackpad Click") { inputEditor(side == 0 ? .touchpad : .rs) }
        }
    }
}

private struct SteamPadHapticTest: View {
    let side: Int
    let strength: Double
    let rate: Double
    let spacingMS: Double
    @ObservedObject private var reader = SteamControllerUSB.shared
    var body: some View {
        VStack(alignment: .leading) {
            Button("Test haptics") { reader.testFeedback(side: side, strength: strength, rate: rate, spacingMS: spacingMS) }
            Text("Short pulses while this pad moves the mouse, including trackball momentum.").font(.caption).foregroundStyle(.secondary)
            if !reader.feedbackStatus.isEmpty { Text(reader.feedbackStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct GyroNotificationToggle: View {
    @AppStorage(PadNotificationPreferences.gyroKey) private var enabled = true
    var body: some View {
        Toggle("Gyro on/off notifications", isOn: Binding(get: { enabled }, set: { enabled = $0; PadHUD.gyroSwitches = $0 }))
            .help("Applies to all profiles. Layer and calibration notifications keep their own settings.")
    }
}
