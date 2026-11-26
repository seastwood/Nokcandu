import SwiftUI
import GameController
import NokcanduCore

@MainActor final class ControllerOwnershipCoordinator {
    static let shared = ControllerOwnershipCoordinator()
    private var started = false
    func start() {
        guard !started else { return }
        started = true
        SteamControllerUSB.shared.applyOwnershipPreference()
    }
    func setEnabled(_ on: Bool) {
        ControllerOwnershipPreference.enabled = on
        SteamControllerUSB.shared.applyOwnershipPreference()
    }
}

struct ControllerOwnershipSettings: View {
    @ObservedObject private var steam = SteamControllerUSB.shared
    @State private var enabled = ControllerOwnershipPreference.enabled
    @State private var takeover = ControllerTakeover.preference
    var body: some View {
        Section("Controller ownership") {
            Toggle("Give Nokcandu exclusive Steam Controller access", isOn: Binding(get: { enabled }, set: { on in
                enabled = on
                ControllerOwnershipCoordinator.shared.setEnabled(on)
            }))
            Text("Keeps Steam Controllers owned while Nokcandu runs, including in the background and with mappings off. Your profile continues to send its mapped output. Quit Nokcandu or turn this off to release exclusive access. If another app already owns a controller, Nokcandu shows it as blocked.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Supports Steam Controllers over USB, receiver/Puck and Bluetooth.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hide other controllers from Mac games while a profile maps them", isOn: Binding(get: { takeover }, set: { on in
                takeover = on
                ControllerTakeover.preference = on
            }))
            Text("DualShock 4, DualSense, Xbox Wireless (Bluetooth) and Switch Pro: while a Mac app or CrossOver game is in front with a profile that sends only its own mappings (Routing: Only what this profile maps) or an emulated controller, Nokcandu opens the controller exclusively (kIOHIDOptionsTypeSeizeDevice) and reads it itself, so the game sees only the profile's output, not the controller as well. Given back to macOS as soon as the profile stops applying. Nokcandu's own Windows games and streams aren't affected.")
                .font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    Text(steam.status)
                    ForEach(steam.accessSummary, id: \.self) { Text($0) }
                    ForEach(ControllerTakeover.shared.summary, id: \.self) { Text($0) }
                    ForEach(GCController.controllers().filter { $0.extendedGamepad != nil }, id: \.self) { controller in
                        Text("\(controller.vendorName ?? "Controller"): shared macOS controller path")
                    }
                }.font(.caption).textSelection(.enabled)
            }
            Button("Retry Controller Access") { steam.retryCapture() }
            Text("If another app already owns the controller exclusively, quit that app and retry. Native Steam closing also retries paused capture automatically. This setting does not create a native Mac virtual gamepad.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
