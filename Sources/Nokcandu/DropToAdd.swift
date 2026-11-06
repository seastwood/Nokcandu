import SwiftUI
import UniformTypeIdentifiers
import NokcanduCore

/// Dropping things on the library window adds them: a setup program, disc images, a game folder, or games made
/// with Nokcandu (or a folder of them).
enum DropToAdd {
    enum Kind: Equatable {
        case installer(URL)
        case discs([URL])
        case gameFolder(URL)
        case nokcanduGames([URL])          // folders holding Nokcandu game apps
        case unknown(String)
    }

    static let discTypes = Set(Discs.imageTypes.map { $0.lowercased() })

    static func classify(_ urls: [URL]) -> Kind {
        let fm = FileManager.default
        guard !urls.isEmpty else { return .unknown("Nothing to add.") }
        let ext = Set(urls.map { $0.pathExtension.lowercased() })
        if ext.isSubset(of: discTypes) { return .discs(Discs.sorted(urls)) }
        if urls.count == 1, ["exe", "msi"].contains(urls[0].pathExtension.lowercased()) { return .installer(urls[0]) }
        if urls.allSatisfy({ $0.pathExtension == "app" && GameLibrary.inspect($0) != nil }) {
            return .nokcanduGames(Array(Set(urls.map { $0.deletingLastPathComponent() })))
        }
        if urls.count == 1, fm.isDirectory(urls[0]) {
            let found = LibraryDiscovery.folders(in: urls[0], depth: 3, known: [])
            if !found.isEmpty { return .nokcanduGames(found.map(\.folder)) }
            return .gameFolder(urls[0])
        }
        return .unknown("Drop a setup program (.exe or .msi), disc images, a game folder, or games made with Nokcandu.")
    }

    /// A name for the new game from what was dropped ("setup.exe" in "Age of Empires II" → "Age of Empires II").
    static func name(for u: URL) -> String {
        var base = u.deletingPathExtension().lastPathComponent
        let generic = ["setup", "install", "installer", "autorun", "launcher", "start", "game"]
        if generic.contains(base.lowercased()) { base = u.deletingLastPathComponent().lastPathComponent }
        base = base.replacingOccurrences(of: #"(?i)[ _-]*(disc|disk|cd|dvd)[ _-]*\d+$"#, with: "", options: .regularExpression)
        return base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// After dropping a game folder: where it is, or a copy where you choose.
struct DropFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @State private var name = ""
    @State private var copy = false
    @State private var copyTo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(folder.lastPathComponent)").font(.title2.bold())
            TextField("Game name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Game files", selection: $copy) {
                Text("Use it where it is").tag(false)
                Text("Copy it").tag(true)
            }.pickerStyle(.radioGroup)
            if copy {
                CopyDestinationPicker(destination: $copyTo, source: folder)
            } else {
                Text("Nothing is copied. Nokcandu keeps this folder unchanged and tells you if the game changes files in it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Game") {
                    model.installer.startCustom(name: name, source: .folder, library: model.games, inputs: [
                        "folderPath": folder.path, "folderMode": copy ? "copy" : "existing", "copyDestination": copy ? (copyTo?.path ?? "") : "",
                    ])
                    model.showInstaller = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { name = DropToAdd.name(for: folder) }
    }
}
