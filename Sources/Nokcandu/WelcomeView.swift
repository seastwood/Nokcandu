import SwiftUI
import NokcanduCore

/// First run: a choice of what to start with — remapping, streams or Windows games. Only the games path
/// needs Rosetta and the engine, so its checklist (also Setup Checklist…) is a page of its own.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedFeatures = AppFeatures.current
    @State private var rosetta = Setup.rosettaInstalled
    @State private var engine = Setup.engineReady
    @State private var working: String?
    @State private var log: [String] = []
    let silicon = Setup.isAppleSilicon

    var ready: Bool { silicon && rosetta && engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.welcomePage {
            case .choose: chooser
            case .games: gamesSetup
            }
        }
        .padding(24)
        .frame(width: 560)
        .onDisappear { model.finishFeatureWelcome(model.features) }
    }

    func header(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder var chooser: some View {
        header("Welcome to Nokcandu", "Choose what belongs in your workspace. You can change this anytime in Settings → General.")
        FeatureChoices(selection: $selectedFeatures)
        Text("Hidden features keep their saved content. Only Games needs Rosetta and a Wine download; you can set those up later.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            if selectedFeatures.contains(.games) {
                Button("Set Up Windows Games…") {
                    model.finishFeatureWelcome(selectedFeatures)
                    model.sidebarTab = .games; model.welcomePage = .games
                }
            }
            Spacer()
            Button("Continue") {
                model.finishFeatureWelcome(selectedFeatures)
                if let feature = selectedFeatures.visible.first { model.sidebarTab = feature }
                dismiss()
            }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder var gamesSetup: some View {
        header("Windows games", "Play the Windows games you own on this Mac. Each game becomes its own Mac app.")
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
        if ready {
            Divider()
            Text("Add your first game").font(.headline)
            choice("opticaldisc", "From a disc or installer", "Insert a disc, or choose an .iso or a setup program. Nokcandu runs the installer and turns the game into its own Mac app.") {
                dismiss(); model.showInstaller = true
            }
            choice("bag", "From a store", "Steam, Battle.net, EA, Ubisoft, GOG or Epic: set up the store once, and each game you install in it gets its own Mac app.") {
                dismiss(); model.openStores()
            }
            choice("folder", "A game you already have", "A game folder on this Mac or a drive (it stays where it is), a game from another Wine app, or a Mac game.") {
                dismiss(); model.showInstaller = true
            }
            Text("The first time a game needs something — a drive, the mouse for raw input, the microphone — macOS asks once for that game. Allow it, or change it later in System Settings → Privacy & Security.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        Text("Only use games you own. Nokcandu isn't affiliated with Microsoft, Valve, Blizzard or Apple. Games with kernel anti-cheat generally can't run under Wine.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Back") { model.welcomePage = .choose }.disabled(working != nil)
            Spacer()
            Button(ready ? "Done" : "Later") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    func choice(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// The same three choices on first run and in General settings.
struct FeatureChoices: View {
    @Binding var selection: AppFeatures
    var body: some View {
        ForEach(AppFeature.allCases) { feature in
            Toggle(isOn: Binding(get: { selection.contains(feature) }, set: { on in
                var next = selection
                if on { next.enabled.insert(feature) } else { next.enabled.remove(feature) }
                selection = next
            })) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: feature.symbol).frame(width: 24).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(feature.title).font(.body.weight(.semibold))
                            Text(feature.stability).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .foregroundStyle(feature.isExperimental ? Color.orange : Color.green)
                                .background(Capsule().fill((feature.isExperimental ? Color.orange : Color.green).opacity(0.15)))
                        }
                        Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch).padding(.vertical, 5)
        }
    }
}
