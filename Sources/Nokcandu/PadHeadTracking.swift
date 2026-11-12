import AppKit
import CoreMotion
import SwiftUI
import NokcanduCore

/// Experimental profile-selected source. Does not change pairing or audio configuration.
@MainActor
final class PadHeadTracking: ObservableObject {
    static let shared = PadHeadTracking()
    @Published private(set) var enabled = false
    @Published private(set) var status = "Not started"
    @Published private(set) var profileID: String?
    private var settings: PadHeadMotionSettings?
    private var motionActive = false
    /// Refresh after input/layer transitions too, even if no headphone sample arrives between them.
    @discardableResult func refreshActivation() -> Bool {
        let active = enabled && settings.map { DesktopPad.shared.headMotionAllowed(settings: $0) } == true
        if active != motionActive {
            transform.recenter(); stickTransform.recenter(); motionActive = active
            DesktopPad.shared.releaseHeadStick()
        }
        return active
    }
    func configure(profileID: String?, settings: PadHeadMotionSettings?) {
        let next = settings?.included == true ? settings?.normalized : nil
        guard self.profileID != profileID || self.settings != next else { return }
        let sourceChanged = self.profileID != profileID || self.settings?.enabled != next?.enabled
        self.profileID = profileID; self.settings = next
        transform.recenter(); stickTransform.recenter(); DesktopPad.shared.releaseHeadStick(); lastPID = nil
        if sourceChanged { setEnabled(profileID != nil && next?.enabled == true) }
    }
    func retry() {
        guard profileID != nil, settings?.enabled == true else { return }
        setEnabled(true)
    }
    private var manager: CMHeadphoneMotionManager?
    private var sessionID = UUID()
    private var transform = PadHeadMotion()
    private var stickTransform = PadHeadStick()
    private var lastPID: pid_t?
    private func setEnabled(_ on: Bool) {
        sessionID = UUID()
        manager?.stopDeviceMotionUpdates(); manager = nil
        enabled = false; motionActive = false; transform.recenter(); stickTransform.recenter(); DesktopPad.shared.releaseHeadStick(); lastPID = nil
        guard on else { status = "Off"; return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else {
            status = "Requires a packaged build with a motion permission description"; return
        }
        // Construct/access CoreMotion only for an explicitly opted-in active profile.
        let manager = CMHeadphoneMotionManager()
        self.manager = manager
        guard manager.isDeviceMotionAvailable else { status = "No compatible headphone motion available"; return }
        enabled = true; status = "Waiting for headphone motion"
        let session = sessionID
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.sessionID == session else { return }
                guard let motion, error == nil else {
                    self.setEnabled(false); self.status = "Headphone motion stopped or permission unavailable"; return
                }
                guard let settings = self.settings, settings.enabled else { return }
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if self.lastPID != pid { self.transform.recenter(); self.stickTransform.recenter(); DesktopPad.shared.releaseHeadStick(); self.lastPID = pid }
                let active = self.refreshActivation()
                if settings.output == .mouse {
                    let (x, y) = self.transform.sample(yaw: motion.attitude.yaw, pitch: motion.attitude.pitch,
                        sensitivity: settings.sensitivity, deadZone: settings.deadZone, smoothing: settings.smoothing, active: active)
                    if x != 0 || y != 0 { DesktopPad.shared.headMovement(settings.invertX ? -x : x, settings.invertY ? -y : y) }
                } else {
                    let (x,y) = self.stickTransform.sample(yaw:motion.attitude.yaw,pitch:motion.attitude.pitch,
                        range:settings.stickRange,deadZone:settings.deadZone,smoothing:settings.smoothing,active:active)
                    if active { DesktopPad.shared.headStick(settings.invertX ? -x:x,settings.invertY ? -y:y,right:settings.output == .rightStick) }
                    else { DesktopPad.shared.releaseHeadStick() }
                }
                let status = self.motionActive ? "Headphone motion active" : "Headphone motion paused / waiting for activation"
                if self.status != status { self.status = status }
            }
        }
    }
    func recenter() { transform.recenter(); stickTransform.recenter(); DesktopPad.shared.releaseHeadStick() }
}

struct PadHeadTrackingSettings: View {
    @ObservedObject private var head = PadHeadTracking.shared
    var body: some View {
        Section("Headphone motion") {
            Text("Add AirPods / Headphones using Add Device in a controller profile. Its output, sensitivity and response are saved with that profile and run only while it is active.")
                .font(.caption).foregroundStyle(.secondary)
            Text(head.status).font(.caption)
        }
    }
}

struct PadHeadProfileSettings: View {
    @Binding var settings: PadHeadMotionSettings
    let profileID: String
    let layers: [String]
    let family: Controllers.Family?
    let remove: () -> Void
    let editStick: (Int) -> Void
    @ObservedObject private var head = PadHeadTracking.shared
    var body: some View {
        Section("AirPods / Headphones") {
            Toggle("Use head motion in this profile", isOn: $settings.enabled)
            Text("Head motion can move the mouse or feed this profile’s left/right stick mappings. Requires compatible motion-capable headphones selected by macOS and Motion permission. Adding this source opts this profile in; it starts when this profile becomes active. This does not create a Windows controller or change audio settings.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.enabled {
                Picker("Head motion controls",selection:$settings.output) {
                    ForEach(PadHeadMotionSettings.Output.allCases,id: \.self) { Text($0.title).tag($0) }
                }
                if settings.output != .mouse {
                    Text("Uses the selected stick’s settings and active layer: map its directions to WASD or other keys, macros and actions. For a held radial menu, choose the same stick in the menu, bind a controller button to open it while held, and turn your head to select. Physical stick input combines with head motion; the stronger deflection wins. This is input to Nokcandu’s mapping engine, not a new Windows gamepad.").font(.caption).foregroundStyle(.secondary)
                    Button("Edit \(settings.output == .rightStick ? "right" : "left") stick mappings") { editStick(settings.output == .rightStick ? 1 : 0) }
                    Slider(value:$settings.stickRange,in:0.05...1) { Text("Head turn for full stick") }
                    Text(String(format:"Full deflection: %.0f°",settings.stickRange*180/Double.pi)).font(.caption)
                }
                Picker("Activate head motion", selection: $settings.activation) {
                    ForEach(PadHeadMotionSettings.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.activation == .whileHeld {
                    Picker("Hold button", selection: $settings.activationButton) {
                        ForEach(PadProfiles.Input.padButtons) { Text($0.title(family)).tag($0) }
                    }
                    Text("Adds headphone motion while this button is physically held. Controller gyro and this button’s other mappings continue normally. Set the button to Nothing if you want it only for activation.").font(.caption).foregroundStyle(.secondary)
                } else if settings.activation == .inLayer {
                    Picker("Active layer", selection: $settings.activationLayer) {
                        Text("Choose a layer…").tag("")
                        if !settings.activationLayer.isEmpty && !layers.contains(settings.activationLayer) {
                            Text("Missing: \(settings.activationLayer)").tag(settings.activationLayer)
                        }
                        ForEach(layers, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Headphone motion is inactive outside this layer. Use an ordinary Hold Layer or Toggle Layer button to enter it; controller gyro keeps its existing layer settings.").font(.caption).foregroundStyle(.secondary)
                }
                if settings.output == .mouse { Slider(value: $settings.sensitivity, in: 100...5000) { Text("Sensitivity") } }
                Slider(value: $settings.smoothing, in: 0.05...1) { Text("Response") }
                Slider(value: $settings.deadZone, in: 0...0.01) { Text("Dead zone") }
                Toggle("Invert left / right", isOn: $settings.invertX)
                Toggle("Invert up / down", isOn: $settings.invertY)
            }
            Text("Gyro off while held pauses controller and headset motion together. Mouse output uses the foreground application’s capture rule. Hardware and audio coexistence need testing.")
                .font(.caption).foregroundStyle(.secondary)
            if head.profileID == profileID {
                Text(head.status).font(.caption)
                Button("Recenter Head Motion") { head.recenter() }.disabled(!head.enabled)
                if !head.enabled && settings.enabled { Button("Retry Headphone Motion") { head.retry() } }
            } else {
                Text("This profile is not currently active. Its headphone source is saved for when you use it.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove Headphone Source", role: .destructive, action: remove)
        }
    }
}
