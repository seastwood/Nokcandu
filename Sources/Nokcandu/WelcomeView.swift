import SwiftUI
import NokcanduCore

/// First run (and Setup Checklist…): what this Mac needs before games can be installed.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var rosetta = Setup.rosettaInstalled
    @State private var engine = Setup.engineReady
    @State private var working: String?
    @State private var log: [String] = []
    let silicon = Setup.isAppleSilicon

    var ready: Bool { silicon && rosetta && engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Nokcandu").font(.title2.bold())
                    Text("Play the Windows games you own on this Mac. Each game becomes its own Mac app.")
                        .foregroundStyle(.secondary)
                }
            }
            step("Apple silicon Mac", ok: silicon,
                 detail: silicon ? "This Mac has an Apple chip." : "Nokcandu needs a Mac with an Apple chip (M1 or later).") { EmptyView() }
            step("Rosetta 2", ok: rosetta,
                 detail: "Apple's translator for Intel code. Wine — the engine that runs Windows games — needs it. macOS asks for your password to install it.") {
                if !rosetta { Button("Install Rosetta") { run("rosetta") { try await Setup.installRosetta() } }.disabled(working != nil) }
            }
            step("Game engine", ok: engine,
                 detail: "The tested Wine engine and graphics translators from the open-source Sikarugir project (about 260 MB download, 1.1 GB on disk), checked file by file against the versions Nokcandu was tested with.") {
                if !engine {
                    Button("Download") { run("engine") { try await Setup.downloadTestedEngine(log: logger) } }
                        .disabled(working != nil || !rosetta)
                }
            }
            if let w = working {
                HStack { ProgressView().controlSize(.small); Text(w == "engine" ? "Downloading and checking the engine…" : "Installing Rosetta…") }
            }
            if !log.isEmpty {
                Text(log.suffix(4).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Divider()
            Text("Only use games you own. Nokcandu isn't affiliated with Microsoft, Valve, Blizzard, Apple or CodeWeavers. Games with kernel anti-cheat generally can't run under Wine.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if ready {
                    Button("Set Up Steam") { dismiss(); model.installerStartsSteamHost = true; model.showInstaller = true }
                    Button("Install a Game…") { dismiss(); model.showInstaller = true }.buttonStyle(.borderedProminent)
                }
                Button(ready ? "Done" : "Later") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    var logger: @Sendable (String) -> Void { { line in Task { @MainActor in log.append(line) } } }

    func run(_ what: String, _ job: @escaping () async throws -> Void) {
        working = what
        Task {
            do { try await job() } catch { model.fail(error) }
            rosetta = Setup.rosettaInstalled; engine = Setup.engineReady; working = nil
        }
    }

    @ViewBuilder
    func step<B: View>(_ title: String, ok: Bool, detail: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            button()
        }
    }
}
