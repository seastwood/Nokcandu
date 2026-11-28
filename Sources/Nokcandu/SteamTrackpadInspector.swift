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
        // A change made in a layer becomes that layer's own (see stickBinding).
        let layer = layerIndex
        return Binding(get: { baseSteamPad(side) }, set: { value in
            if layer > 0 {
                if side == 0 { profile.layers[layer].steamLeftTrackpad = value } else { profile.layers[layer].steamRightTrackpad = value }
            } else if side == 0 { profile.steamLeftTrackpad = value } else { profile.steamRightTrackpad = value }
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
                    // Into the layer being edited, so setting this up in a layer doesn't add keys to the base layer.
                    for (input, key) in zip(directions, side == 0 ? [13, 1, 0, 2] : [126, 125, 123, 124]) { profile.layers[layerIndex][input] = .as(.key(key)) }
                }
                // Buttons start as a four-way radial, like a D-pad, ready to set.
                if mode == .buttons, (settings.wrappedValue.zoneLayout ?? .off) == .off { settings.wrappedValue.zoneLayout = .ring4 }
            })) {
                Text(side == 0 ? "Existing touchpad settings" : family == .steam2026 ? "Right stick, as it is (alongside the joystick)" : "Joystick settings").tag(PadSteamTrackpadSettings.Mode.existing)
                Text("Trackpad mouse").tag(PadSteamTrackpadSettings.Mode.mouse)
                Text("Trackball mouse").tag(PadSteamTrackpadSettings.Mode.trackball)
                Text(side == 0 ? "Four directions (W A S D…)" : "Four directions (arrows…)").tag(PadSteamTrackpadSettings.Mode.directions)
                Text(side == 0 ? "Analog stick (left stick)" : "Analog stick (right stick)").tag(PadSteamTrackpadSettings.Mode.stick)
                Text(side == 0 ? "Mouse-like stick (left stick)" : "Mouse-like stick (right stick)").tag(PadSteamTrackpadSettings.Mode.velocityStick)
                Text("Buttons (zones you set)").tag(PadSteamTrackpadSettings.Mode.buttons)
                Text("Scroll wheel (circle)").tag(PadSteamTrackpadSettings.Mode.dial)
                Text("Absolute mouse region").tag(PadSteamTrackpadSettings.Mode.absolute)
                Text("Drawn gestures").tag(PadSteamTrackpadSettings.Mode.gestures)
            }
            if settings.wrappedValue.mode == .absolute { PadRegionSettings(settings:settings) }
            if settings.wrappedValue.mode == .gestures {
                slider("Gesture tolerance", Binding(get:{ settings.wrappedValue.gestureTolerance ?? 0 },set:{ settings.wrappedValue.gestureTolerance = $0 }),0...0.4,"%.0f%%",scale:100,info:"0 requires the exact sequence of directions. Higher accepts small differences. No command fires until you lift your finger.")
                slider("Stroke length", Binding(get:{ settings.wrappedValue.gestureStroke ?? 0.18 },set:{ settings.wrappedValue.gestureStroke = $0 }),0.08...0.4,"%.0f%%",scale:100)
            }
            slider("Pad angle", Binding(get: { settings.wrappedValue.rotation ?? PadSteamTrackpadSettings.defaultRotation(side: side) }, set: { settings.wrappedValue.rotation = $0 }), -30...30, "%.0f°", info: "Turns the pad’s axes and tap/click zones to match your thumb’s sweep, in every behavior. 0° is straight up/down and left/right. Circular scrolling keeps the same steps and direction; its zones still turn. The picture shows the angle.")
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
                Text(side == 0 ? "Works as the left stick, alongside the joystick: whichever is pushed further counts. Games see a real analog stick, so you can walk slowly and run." : "Works as the right stick with the dead zone and angle above.").font(.caption).foregroundStyle(.secondary)
            }
            if settings.wrappedValue.mode == .velocityStick {
                slider("Full tilt at", Binding(get: { PadVelocityStick.fullSpeed(settings.wrappedValue) }, set: { settings.wrappedValue.velocityFullSpeed = $0 }), 0.2...6, "%.1f /s", info: "How fast your finger moves, in pad widths a second, to push the stick all the way. Lower is more sensitive.")
                slider("Left and right", Binding(get: { settings.wrappedValue.velocityXScale ?? 1 }, set: { settings.wrappedValue.velocityXScale = abs($0 - 1) < 0.01 ? nil : $0 }), 0.25...3, "%.2f×", info: "Sensitivity across. Above 1 tilts further for the same finger speed.")
                slider("Up and down", Binding(get: { settings.wrappedValue.velocityYScale ?? 1 }, set: { settings.wrappedValue.velocityYScale = abs($0 - 1) < 0.01 ? nil : $0 }), 0.25...3, "%.2f×", info: "Sensitivity up and down. Many games turn slower vertically; raise or lower this to match.")
                slider("Response curve", Binding(get: { settings.wrappedValue.velocityCurve ?? 1 }, set: { settings.wrappedValue.velocityCurve = abs($0 - 1) < 0.01 ? nil : $0 }), 0.5...3, "%.2f", info: "1 is straight. Higher keeps slow finger movement small, for fine aim, and still reaches full tilt on fast swipes; below 1 is quicker off the centre.")
                slider("Least tilt", Binding(get: { settings.wrappedValue.velocityMinimum ?? 0 }, set: { settings.wrappedValue.velocityMinimum = $0 < 0.005 ? nil : $0 }), 0...0.5, "%.0f%%", scale: 100, info: "Any movement tilts the stick at least this much, to step past a game's own stick dead zone so slow movement isn't lost. Set it just above where the game starts to respond.")
                slider("Speed averaging", Binding(get: { settings.wrappedValue.velocityResponseMS ?? PadVelocityStick.responseMS }, set: { settings.wrappedValue.velocityResponseMS = abs($0 - PadVelocityStick.responseMS) < 0.5 ? nil : $0 }), 2...80, "%.0f ms", info: "How long finger speed is averaged. Lower follows the finger more tightly but shows the pad's jitter; higher is smoother.")
                slider("Back to centre", Binding(get: { settings.wrappedValue.velocityReturnMS ?? PadVelocityStick.responseMS }, set: { settings.wrappedValue.velocityReturnMS = abs($0 - PadVelocityStick.responseMS) < 0.5 ? nil : $0 }), 5...300, "%.0f ms", info: "How quickly the stick returns to centre once your finger stops moving. Higher keeps turning a moment longer.")
                Toggle("Invert up and down", isOn: settings.invertY)
                Toggle("Keep moving after a flick (inertia)", isOn: Binding(get: { settings.wrappedValue.velocityInertia == true }, set: { settings.wrappedValue.velocityInertia = $0 ? true : nil }))
                    .help("After a flick and lift, the stick stays tilted and eases back to centre. Touch the pad again to stop at once.")
                if settings.wrappedValue.velocityInertia == true {
                    slider("Momentum half-life", settings.halfLife, 0.02...0.6, "%.2f s", info: "After a flick and lift, the stick's tilt halves over this time.")
                }
                Text(side == 0 ? "Moves the left stick like a mouse: the faster your finger moves, the further the stick tilts, and it returns to centre when your finger stops. Where you touch doesn't matter. The joystick still works; whichever is pushed further counts." : "Moves the right stick like a mouse: the faster your finger moves, the further the stick tilts, and it returns to centre when your finger stops. Where you touch doesn't matter, so games that only read a stick can be aimed like with a mouse.").font(.caption).foregroundStyle(.secondary)
            }
            if settings.wrappedValue.mode == .directions {
                slider("Centre dead zone", Binding(get: { PadSteamPadZones.deadzone(settings.wrappedValue) }, set: { settings.wrappedValue.deadzone = $0 }), 0.05...0.8, "%.0f%%", scale: 100, info: "How far from the middle of the pad a direction starts. Between two directions, both are held.")
            }
            if settings.wrappedValue.mode == .directions || PadSteamPadZones.edgeSize(settings.wrappedValue) > 0 {
                slider("Feel moving onto a key", Binding(get: { settings.wrappedValue.keyEnterHaptic ?? 0 }, set: { settings.wrappedValue.keyEnterHaptic = $0 < 0.01 ? nil : $0 }), 0...1, "%.0f%%", scale: 100, info: "A click in the pad as your finger moves onto a direction or the edge. 0 is off.")
                slider("Feel moving off a key", Binding(get: { settings.wrappedValue.keyLeaveHaptic ?? 0 }, set: { settings.wrappedValue.keyLeaveHaptic = $0 < 0.01 ? nil : $0 }), 0...1, "%.0f%%", scale: 100, info: "A click as your finger moves off a direction or the edge (not when you lift it). Set it lighter than moving onto a key to tell them apart. 0 is off.")
            }
            if settings.wrappedValue.mode.movesPointer {
                slider("X sensitivity", Binding(get: { settings.wrappedValue.sensitivityX ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityX = $0 }), 200...5000, "%.0f", info: "Horizontal movement across the whole pad.")
                slider("Y sensitivity", Binding(get: { settings.wrappedValue.sensitivityY ?? settings.wrappedValue.sensitivity }, set: { settings.wrappedValue.sensitivityY = $0 }), 200...5000, "%.0f", info: "Vertical movement across the whole pad.")
                slider("Smoothing", Binding(get: { settings.wrappedValue.smoothing ?? PadSteamTrackpadSettings.defaultSmoothing }, set: { settings.wrappedValue.smoothing = $0 }), 0...1, "%.0f%%", scale: 100, info: "Steadies a resting or slow finger and steps aside as it speeds up, so quick movement stays immediate. 0 adds none (a pad whose readings are noisy is still steadied by just that much, on its own). Try this before Small movement steadiness: it has no distance to push through when you change direction.")
                slider("Straight flicks", Binding(get: { settings.wrappedValue.straighten ?? 0 }, set: { settings.wrappedValue.straighten = $0 < 0.5 ? nil : $0 }), 0...40, "%.0f°", info: "A quick swipe that is nearly straight up, down or across goes exactly straight, so a flick doesn’t veer off. The angle is how far from straight still counts; half of it is straightened fully and the rest less and less, so diagonals stay diagonal. Slow, careful movement is never changed, and nothing is delayed. 0° is off.")
                slider("Acceleration", Binding(get: { settings.wrappedValue.acceleration ?? 0 }, set: { settings.wrappedValue.acceleration = $0 < 0.02 ? nil : $0 }), 0...3, "+%.0f%%", scale: 100, info: "Fast finger movement goes further than slow: slow, careful movement keeps your sensitivity, and the faster you swipe the more it is multiplied, up to this much extra. +100% is up to twice as far. Both directions get the same boost, so the pointer’s path keeps its shape, and nothing is delayed. 0 is off.")
                if (settings.wrappedValue.acceleration ?? 0) > 0 {
                    slider("Full acceleration at", Binding(get: { settings.wrappedValue.accelerationSpeed ?? PadSteamTrackpadSettings.defaultAccelerationSpeed }, set: { settings.wrappedValue.accelerationSpeed = $0 }), 0.5...10, "%.1f /s", info: "How fast your finger moves, in pad widths a second, to get all of the acceleration. It builds gently from a standstill up to this speed. Lower reaches the boost with less effort; higher keeps more of your movement at the set sensitivity.")
                }
                // Superseded by Smoothing: shown only while an older profile still uses it.
                if (settings.wrappedValue.steadiness ?? 0) > 0, (PadProfiles.steamTrackpad(side, profile: profile, all: everything).smoothing ?? 0) == 0 { slider("Small movement steadiness", Binding(get: { settings.wrappedValue.steadiness ?? 0 }, set: { settings.wrappedValue.steadiness = $0 }), 0...5, "%.1f px", info: "Ignores tiny back-and-forth wobble on each axis. 0 follows raw motion. Higher values can steady slow aiming, but the pointer waits for that distance before it follows a change of direction, which can feel like resistance. Prefer Smoothing, and set this to 0 to retire it.") }
                if (settings.wrappedValue.sensitivityX ?? settings.wrappedValue.sensitivity) != (settings.wrappedValue.sensitivityY ?? settings.wrappedValue.sensitivity) {
                    Picker(selection: Binding(get: { settings.wrappedValue.directional }, set: { settings.wrappedValue.directionalSensitivity = $0 })) {
                        ForEach(PadSteamTrackpadSettings.DirectionalSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Directional sensitivity")
                            InfoButton("Your X and Y sensitivities are different. This lets the direction you move adjust them, smoothly: straight up or down counts as Y’s direction, straight across as X’s, and anything in between partly as each.\n\nHighest toward lowest (the default): whichever of X and Y is higher comes down to the lower one’s value as you move towards the lower one’s direction. Moving that way then doesn’t magnify your thumb’s sideways wobble into a zig-zag, and nothing ever moves faster than you set.\nVary X toward Y: X uses Y’s sensitivity when you move straight up or down, its own when you move straight across. Y stays as set.\nVary Y toward X: the same for Y: X’s sensitivity straight across, its own straight up or down.\nVary both: each direction uses its own sensitivity on both axes, so the pointer’s path keeps the shape of your thumb’s.\nOff: X and Y always as set.\n\nOnly how far the pointer moves changes; nothing is delayed.")
                        }
                    }
                }
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
        } header: {
            HStack {
                Text(side == 0 ? "Left Trackpad" : "Right Trackpad")
                Spacer()
                if profile.layers.count > 1 { copyPadMenu(side).font(.callout) }
            }
        }
          footer: {
            Text("Each pad chooses its behavior independently, and a layer can have pad settings of its own. Trackpad mouse follows finger movement; trackball mouse continues after a flick and lift; four directions holds a key or button for each way you push; analog stick works as a real stick. Profile changes, focus changes and lost input cancel momentum.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if settings.wrappedValue.mode == .gestures {
            ForEach(0..<4,id: \.self) { index in
                Section("Gesture \(index+1)") {
                    let pattern = Binding<String>(get:{
                        let list = settings.wrappedValue.gesturePatterns ?? ["U","D","L","R"]
                        return list.indices.contains(index) ? list[index] : ""
                    },set:{ value in
                        var list = settings.wrappedValue.gesturePatterns ?? ["U","D","L","R"]
                        while list.count < 4 { list.append("") }
                        list[index] = PadGestureRecognizer.normalized(value); settings.wrappedValue.gesturePatterns = list
                    })
                    HStack { TextField("Pattern (U D L R)",text:pattern); PadGestureRecordButton(side:side,settings:settings.wrappedValue,pattern:pattern) }
                    inputEditor(PadProfiles.Input.padGesture(side,index))
                }
            }
        }
        if PadSteamPadZones.edgeSize(settings.wrappedValue) > 0 {
            Section {
                inputEditor(PadProfiles.Input.padEdge(side))
            } header: { Text("Pad Edge") } footer: {
                Text("Held while your finger is in the ring at the rim, together with whatever the pad is doing there.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.wrappedValue.mode != .gestures {
            Section {
                inputEditor(PadProfiles.Input.padTap(side))
            } header: { Text("Tap") } footer: {
                Text("A quick touch and lift without moving. Choose “Double” in its settings for a double tap. Gesture mode uses drawings instead of taps.").font(.caption).foregroundStyle(.secondary)
            }
        }
        // How deliberate a touch must be. Both off by default: any touch counts, as it always has.
        Section {
            if settings.wrappedValue.mode != .gestures {
                Toggle("Ignore brief brushes", isOn: Binding(get: { (settings.wrappedValue.shortestTapMS ?? 0) > 0 },
                                                             set: { settings.wrappedValue.shortestTapMS = $0 ? 40 : nil }))
                if (settings.wrappedValue.shortestTapMS ?? 0) > 0 {
                    slider("Shortest tap", Binding(get: { settings.wrappedValue.shortestTapMS ?? 40 }, set: { settings.wrappedValue.shortestTapMS = $0 }), 10...150, "%.0f ms",
                           info: "A touch shorter than this isn't a tap, so brushing the pad does nothing. Taps still have to be shorter than 200 ms.")
                }
            }
            let reportsPressure = SteamControllerUSB.shared.model == .steam2026
            if reportsPressure || (settings.wrappedValue.pressureNeeded ?? 0) > 0 {
                Toggle("Need a firm press", isOn: Binding(get: { (settings.wrappedValue.pressureNeeded ?? 0) > 0 },
                                                         set: { settings.wrappedValue.pressureNeeded = $0 ? 0.3 : nil }))
                if (settings.wrappedValue.pressureNeeded ?? 0) > 0 {
                    slider("Pressure needed", Binding(get: { settings.wrappedValue.pressureNeeded ?? 0.3 }, set: { settings.wrappedValue.pressureNeeded = $0 }), 0.05...0.9, "%.0f%%", scale: 100,
                           info: "Taps, zones and held touches count only once your thumb presses at least this hard. Moving the pointer and clicking aren't affected.")
                }
            }
        } header: { Text("Touch") } footer: {
            Text(SteamControllerUSB.shared.model == .steam2026 || (settings.wrappedValue.pressureNeeded ?? 0) > 0
                 ? "Off, any touch counts. The 2026 Steam Controller's trackpads report pressure; on a controller that doesn't, a pressure setting is ignored."
                 : "Off, any touch counts. To act only on a firm press, set a zone's Click instead of its Tap. Trackpads that report pressure (the 2026 Steam Controller) also offer a pressure setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            let buttons = settings.wrappedValue.mode == .buttons
            Picker(buttons ? "Layout" : "Zones", selection: Binding(get: { settings.wrappedValue.zoneLayout ?? .off }, set: { settings.wrappedValue.zoneLayout = $0 == .off ? nil : $0 })) {
                ForEach(PadSteamZoneLayout.allCases.filter { !buttons || $0 != .off }, id: \.self) { Text($0.title).tag($0) }
            }
            let layout = settings.wrappedValue.zoneLayout ?? .off
            if layout != .off {
                Picker("Zone", selection: $padZoneShown) {
                    ForEach(Array(layout.names.enumerated()), id: \.offset) { n, name in Text(name).tag(n) }
                }
                .pickerStyle(.segmented)
                let n = min(padZoneShown, layout.names.count - 1)
                LabeledContent(buttons ? "While touched" : "Tap") { EmptyView() }
                inputEditor(PadProfiles.Input.padZoneTap(side, n))
                LabeledContent("Click") { EmptyView() }
                inputEditor(PadProfiles.Input.padZoneClick(side, n))
            }
        } header: { Text(settings.wrappedValue.mode == .buttons ? "Buttons" : "Zones") } footer: {
            if settings.wrappedValue.mode == .buttons {
                Text("The pad is only these buttons: the one under your thumb is held while it's there (slide to another and that one's held instead), and clicking presses its Click. Set each to a key, mouse button, controller button, layer, macro or anything else. Radial layouts leave the middle free.").font(.caption).foregroundStyle(.secondary)
            } else {
            Text("Divide the pad so a tap, double tap or click in each part does something of its own, whatever the pad's behavior. A zone with nothing set uses the pad's ordinary tap or click. The zones turn with the pad angle and show on the picture.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.wrappedValue.mode == .directions {
            ForEach(PadProfiles.Input.padDirections(side), id: \.self) { input in
                Section(input.title(family)) { inputEditor(input) }
            }
        }
        // The 2026 controller's right pad has a click of its own (its right stick click is the stick's).
        if settings.wrappedValue.mode == .existing, !(family == .steam2026 && side == 1) {
            if side == 0 { legacyTouchpadInspector } else { joystickInspector(1) }
        } else {
            Section("Trackpad Click") { inputEditor(side == 0 ? .touchpad : family == .steam2026 ? .rpclick : .rs) }
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
