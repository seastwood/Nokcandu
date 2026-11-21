import SwiftUI
import AppKit
import NokcanduCore

/// Settings → Updates → Apple silicon engines: Wine engines from other projects that run Intel Windows programs
/// without Rosetta. Any source can be added (a GitHub repository and a file pattern), or an engine from a file, so
/// Nokcandu never depends on one of them.
struct ExternalEnginesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var installed = ExternalEngines.installed()
    @State private var sources = ExternalEngines.sources()
    @State private var busy: String?
    @State private var status = ""
    @State private var addingSource = false

    var body: some View {
        SettingsSection(title: "Other Wine engines (preview)", info: "Engines from other projects. Apple silicon ones are Wine built for Apple silicon, with an x86 emulator (FEX) that runs Intel Windows programs instead of Rosetta, which macOS 28 mostly removes. These come from other projects and are kept exactly as their makers built them, so some of Nokcandu's features that work by adjusting the engine aren't available with them: raw mouse input from Nokcandu's helper, the resizable game window, the audio buffer setting, and the game's own name in the Dock. Pick one in a game's Wine settings: it downloads then, and Roll Back returns to the previous engine. Here you can add other sources, or any Wine engine you've downloaded (\"Add Engine From File…\"), Intel or Apple silicon, and remove installed ones. An engine that isn't signed by its makers is copied in, and Nokcandu's own features work with it as with its usual engines.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(installed, id: \.id) { e in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).bold()
                            Text("Wine \(e.wineVersion) · \(e.arch == .arm64 ? "Apple silicon" : "Intel (Rosetta)")\(e.sealed ? " · kept as built" : "") · installed \(e.installedAt.formatted(date: .abbreviated, time: .omitted))\(RuntimeManager.manifest(for: e.id)?.selfTest == false ? " · didn't pass the startup check" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { remove(e) }.disabled(busy != nil)
                    }
                }
                if installed.isEmpty { Text("None installed.").font(.caption).foregroundStyle(.secondary) }
                Divider()
                ForEach(sources) { s in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text([s.note, "github.com/\(s.repo)"].compactMap { $0 }.joined(separator: " "))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if ExternalEngines.builtIn.contains(where: { $0.id == s.id }) == false {
                            Button("Remove Source") { try? ExternalEngines.removeSource(s.id); reload() }.disabled(busy != nil)
                        }
                    }
                }
                HStack {
                    Button("Add Source…") { addingSource = true }.disabled(busy != nil)
                    Button("Add Engine From File…") { addFromFile() }.disabled(busy != nil)
                    if busy != nil { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Text("Choose these in a game's Wine settings. Needs macOS 26.5 or later; only files with a published SHA-256 are downloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $addingSource) { AddEngineSourceSheet { reload() } }
    }

    private func reload() { installed = ExternalEngines.installed(); sources = ExternalEngines.sources() }

    private func run(_ key: String, _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) {
        busy = key; status = ""
        Task {
            do { try await work { line in Task { @MainActor in status = line } } }
            catch { await MainActor.run { status = error.localizedDescription } }
            await MainActor.run { busy = nil; reload() }
        }
    }
    private func addFromFile() {
        let p = NSOpenPanel()
        p.message = "Choose a Wine engine for macOS: an app, a .zip, a .tar.xz, or a folder with bin/wine (Intel or Apple silicon)."
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        run("file") { log in _ = try await ExternalEngines.install(file: url, log: log) }
    }
    private func remove(_ e: ExternalEngines.Info) {
        do { try ExternalEngines.remove(id: e.id, games: model.games); reload(); status = "Removed \(e.title) (moved to the Trash)." }
        catch { status = error.localizedDescription }
    }
}

/// A GitHub repository whose releases carry an Apple silicon Wine engine.
struct AddEngineSourceSheet: View {
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repo = ""
    @State private var pattern = #"-arm64\.(zip|tar\.xz)$"#
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an Engine Source").font(.title3.bold())
            Text("A GitHub project that publishes Apple silicon Wine builds. Nokcandu installs its newest release whose file name matches the pattern and has a published SHA-256.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
            TextField("Repository (owner/name)", text: $repo)
            TextField("File name pattern (regular expression)", text: $pattern)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let id = ExternalEngines.slug(repo)
                    let s = ExternalEngines.Source(id: id, name: name.isEmpty ? repo : name, repo: repo.trimmingCharacters(in: .whitespaces),
                                                   asset: pattern, homepage: "https://github.com/\(repo)", license: "see the project")
                    do { try ExternalEngines.addSource(s); done(); dismiss() } catch { problem = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(repo.isEmpty || pattern.isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }
}
