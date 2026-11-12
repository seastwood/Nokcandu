import AppKit
import GameController
import SwiftUI
import NokcanduCore

struct PadDiagnosticsSettings: View {
    @ObservedObject private var pad = DesktopPad.shared
    @ObservedObject private var capture = PadCapture.shared
    var body: some View {
        Section("Controller diagnostics") {
            Toggle("Show session input diagnostics", isOn: $pad.diagnosticsEnabled)
            if pad.diagnosticsEnabled {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Foreground: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "None")")
                        Text("Profile: \(pad.status)")
                        Text("Accessibility: \(pad.trusted ? "Granted" : "Unavailable") · \(capture.status)")
                        Text("Steam: \(NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.valvesoftware.steam" } ? "Running" : "Not running")")
                        ForEach(Controllers.connected()) { d in
                            Text("\(d.displayName) · \(d.ids) · \(d.bluetooth ? "Bluetooth" : "USB/receiver") · \(d.isGamepad ? "Gamepad interface" : "Other HID interface")")
                        }
                        Text("GameController readers: \(GCController.controllers().filter { $0.extendedGamepad != nil }.count)")
                        ForEach(pad.diagnosticCounts.keys.sorted(), id: \.self) { key in Text("\(key): \(pad.diagnosticCounts[key] ?? 0)") }
                        ForEach(pad.diagnosticTimings.keys.sorted(), id: \.self) { name in
                            if let timing = pad.diagnosticTimings[name] {
                                Text(String(format: "%@: mean %.3f ms · max %.3f ms · %ld/%ld above %.0f ms", name, timing.meanSeconds * 1000, timing.maximumSeconds * 1000, timing.overBudgetCount, timing.count, timing.budgetSeconds * 1000))
                            }
                        }
                        Button("Reset Diagnostics") { pad.resetDiagnostics() }
                        Text("Timings measure local handling and timer intervals, including synchronous output work. They do not measure physical-device delivery, queue wait before callback entry, game consumption or screen response. Tick interval uses an 8 ms observation threshold; other work uses 4 ms. These thresholds are diagnostic markers, not performance guarantees.")
                        if let last = pad.lastGyroReceipt { Text("Last motion callback: \(Int(max(0, DesktopPad.now() - last))) seconds ago") }
                        else { Text("No motion callbacks observed in this diagnostic session") }
                        Text("Counters are totals for this app session and show receipt/emission, not target acceptance. Compare before and after starting Steam; a gyro gap alone does not establish exclusive ownership. No raw HID reports are captured and no device mode is changed.")
                    }.font(.caption).textSelection(.enabled)
                }
            }
        }
    }
}
