import SwiftUI
import NokcanduCore

extension ControllerProfileEditor {
    func steamTrackpadBinding(_ side: Int) -> Binding<PadSteamTrackpadSettings> {
        Binding(get: {
            (side == 0 ? PadProfiles.top(profile, all: everything, \.steamLeftTrackpad) : PadProfiles.top(profile, all: everything, \.steamRightTrackpad)) ?? PadSteamTrackpadSettings()
        }, set: { value in
            if side == 0 { profile.steamLeftTrackpad = value } else { profile.steamRightTrackpad = value }
        })
    }
    @ViewBuilder func steamTrackpadInspector(_ side: Int) -> some View {
        let settings = steamTrackpadBinding(side)
        Section {
            Picker("Pad behavior", selection: settings.mode) {
                Text(side == 0 ? "Existing touchpad settings" : "Joystick settings").tag(PadSteamTrackpadSettings.Mode.existing)
                Text("Trackpad mouse").tag(PadSteamTrackpadSettings.Mode.mouse)
                Text("Trackball mouse").tag(PadSteamTrackpadSettings.Mode.trackball)
            }
            Toggle("Touch haptics", isOn: Binding(get: { (settings.wrappedValue.touchFeedback ?? 0) > 0 }, set: { settings.wrappedValue.touchFeedback = $0 ? 0.2 : nil }))
                .help("One short pulse when your finger first touches this pad, even without moving. Independent of Movement haptics.")
            if (settings.wrappedValue.touchFeedback ?? 0) > 0 {
                slider("Touch strength", Binding(get: { settings.wrappedValue.touchFeedback ?? 0.2 }, set: { settings.wrappedValue.touchFeedback = $0 }), 0.05...1, "%.0f%%", scale: 100)
            }
            if settings.wrappedValue.mode != .existing {
                slider("X sensitivity", Binding(get: { settings.wrappedValue.sensitivityX ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityX = $0 }), 200...5000, "%.0f", info: "Horizontal movement across the whole pad.")
                slider("Y sensitivity", Binding(get: { settings.wrappedValue.sensitivityY ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityY = $0 }), 200...5000, "%.0f", info: "Vertical movement across the whole pad.")
                slider("Smoothing", Binding(get: { settings.wrappedValue.smoothing ?? PadSteamTrackpadSettings.defaultSmoothing }, set: { settings.wrappedValue.smoothing = $0 }), 0...1, "%.0f%%", scale: 100, info: "Steadies a resting or slow finger and steps aside as it speeds up, so quick movement stays immediate. 0 follows the pad’s raw readings. Try this before Small movement steadiness: it has no distance to push through when you change direction.")
                slider("Pad angle", Binding(get: { settings.wrappedValue.rotation ?? PadSteamTrackpadSettings.defaultRotation(side: side) }, set: { settings.wrappedValue.rotation = $0 }), -30...30, "%.0f°", info: "Turns the pad’s axes to match your thumb’s natural sweep, so a sideways swipe moves the pointer straight across. \(side == 0 ? "−15" : "15")° is the angle Valve uses for this pad; 0 uses the pad’s raw axes.")
                slider("Small movement steadiness", Binding(get: { settings.wrappedValue.steadiness ?? 0 }, set: { settings.wrappedValue.steadiness = $0 }), 0...5, "%.1f px", info: "Ignores tiny back-and-forth wobble on each axis. 0 follows raw motion. Higher values can steady slow aiming, but the pointer waits for that distance before it follows a change of direction, which can feel like resistance. Prefer Smoothing, and keep this at 0 unless you still need it.")
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
            Text("Each pad chooses its behavior independently. This choice applies to all layers. Trackpad mouse follows finger movement; trackball mouse continues after a flick and lift. Profile changes, focus changes and lost input cancel momentum.")
                .font(.caption).foregroundStyle(.secondary)
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
