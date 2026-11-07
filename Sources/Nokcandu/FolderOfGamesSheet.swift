import SwiftUI
import NokcanduCore

/// Add a Folder of Games: every game folder inside one folder, ticked, with its program already chosen.
/// Each is added where it is (nothing copied), one after another.
struct FolderOfGamesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let root: URL
    @State private var found: [FolderOfGames.Candidate]?
    @State private var ticked: Set<String> = []
    @State private var results: [String: FolderOfGames.Outcome] = [:]
    @State private var current: String?
    @State private var adding = false
    @State private var stop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Folder of Games").font(.title2.bold())
            Text(root.path.replacingOccurrences(of: NokPaths.home.path, with: "~"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let found {
                if found.isEmpty {
                    Text("No game folders found here. Nokcandu looks for a Windows program (.exe) in each folder, skipping setup programs, uninstallers and servers. Folders already in your library are left out.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Each ticked game is added where it is: nothing is copied, and Nokcandu keeps the folders unchanged. Check the name and program; you can change both later.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    List {
                        ForEach(Binding(get: { self.found ?? [] }, set: { self.found = $0 })) { $c in
                            row($c)
                        }
                    }
                    .frame(minHeight: 260)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Looking for games…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                if let found, !found.isEmpty, !adding, results.isEmpty {
                    Button(ticked.count == found.count ? "Untick All" : "Tick All") {
                        ticked = ticked.count == found.count ? [] : Set(found.map(\.id))
                    }
                }
                if adding { Text(summary).font(.callout).foregroundStyle(.secondary) }
                else if !results.isEmpty { Text(summary).font(.callout) }
                Spacer()
                if adding {
                    Button("Stop After This Game") { stop = true }.disabled(stop)
                } else if results.isEmpty {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(ticked.count == 1 ? "Add 1 Game" : "Add \(ticked.count) Games") { start() }
                        .keyboardShortcut(.defaultAction).disabled(ticked.isEmpty)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22).frame(width: 620)
        .interactiveDismissDisabled(adding)
        .task {
            let library = model.games, root = root
            let list = await Task.detached(priority: .userInitiated) { FolderOfGames.scan(root, library: library) }.value
            found = list
            ticked = Set(list.filter(\.likely).map(\.id))
        }
    }

    @ViewBuilder func row(_ c: Binding<FolderOfGames.Candidate>) -> some View {
        let id = c.wrappedValue.id
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { ticked.contains(id) }, set: { if $0 { ticked.insert(id) } else { ticked.remove(id) } }))
                .labelsHidden().disabled(adding || !results.isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: c.name).textFieldStyle(.plain).font(.body.weight(.medium))
                    .disabled(adding || !results.isEmpty)
                let programs = [c.wrappedValue.program] + c.wrappedValue.others.filter { $0 != c.wrappedValue.program }
                if programs.count > 1, !adding, results.isEmpty {
                    Picker("Program", selection: c.program) {
                        ForEach(programs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                } else {
                    Text(c.wrappedValue.program).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            status(id)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder func status(_ id: String) -> some View {
        if current == id { ProgressView().controlSize(.small) }
        else if let r = results[id] {
            switch r {
            case .added: Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .failed(let why): Label("Not added", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption).help(why)
            }
        }
    }

    var summary: String {
        let added = results.values.filter { if case .added = $0 { true } else { false } }.count
        let failed = results.count - added
        if adding { return "Adding \(results.count + 1) of \(ticked.count)…" }
        return failed == 0 ? "Added \(added) game\(added == 1 ? "" : "s")." : "Added \(added); \(failed) not added (hover for why)."
    }

    func start() {
        guard let found else { return }
        let queue = found.filter { ticked.contains($0.id) }
        adding = true; stop = false
        Task {
            for c in queue {
                if stop { break }
                current = c.id
                let r = await FolderOfGames.add(c, library: model.games) { _ in }
                results[c.id] = r
                if case .added = r { model.refresh() }
                try? await Task.sleep(for: .milliseconds(400))
            }
            current = nil; adding = false
            model.refresh()
        }
    }
}

struct FolderOfGamesItem: Identifiable { let url: URL; var id: String { url.path } }
