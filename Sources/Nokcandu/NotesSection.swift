import SwiftUI
import AppKit
import NokcanduCore

struct NotesSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var notes: [GameNote] = []
    @State private var newKind: GameNote.Kind = .tried
    @State private var newText = ""
    @State private var newLink = ""
    @State private var attachSetup = true
    @State private var filter: GameNote.Kind?
    @State private var editing: GameNote.ID?
    @State private var editText = ""
    @State private var expanded: Set<GameNote.ID> = []
    @State private var restoring: GameNote?
    @State private var undo: Profiles.Snapshot?

    var shown: [GameNote] { notes.filter { filter == nil || $0.kind == filter } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // New note
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $newKind) {
                        ForEach(GameNote.Kind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    TextEditor(text: $newText)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if newText.isEmpty {
                                Text(placeholder).foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    HStack {
                        TextField("Link (optional)", text: $newLink).frame(maxWidth: 320)
                        Toggle("Attach current setup", isOn: $attachSetup).toggleStyle(.checkbox)
                            .help(GameNotes.currentSetup(game))
                        Spacer()
                        Button("Add Note", action: add)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if !notes.isEmpty {
                    Divider()
                    HStack {
                        Picker("Show", selection: $filter) {
                            Text("All (\(notes.count))").tag(GameNote.Kind?.none)
                            ForEach(GameNote.Kind.allCases) { k in
                                Text("\(k.title) (\(notes.filter { $0.kind == k }.count))").tag(Optional(k))
                            }
                        }
                        .frame(maxWidth: 260)
                        Spacer()
                        Button("Copy All") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(GameNotes.export(notes, game: game.name), forType: .string)
                            model.say("Notes copied as text.")
                        }
                        .buttonStyle(.link)
                    }
                    if let u = undo {
                        HStack {
                            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.blue)
                            Text("Restored an earlier setup.").font(.caption)
                            Spacer()
                            Button("Undo") {
                                do { try Profiles.undo(u); undo = nil; model.refresh(); model.say("Put the setup back.") } catch { model.fail(error) }
                            }
                        }
                    }
                    ForEach(shown) { n in noteRow(n) }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Notes").font(.headline)
                Text("Kept even if you reinstall or remove the game").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { notes = GameNotes.load(for: game) }
        .confirmationDialog("Restore the setup from \(restoring?.created.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") { if let n = restoring { restore(n) }; restoring = nil }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let p = restoring?.snapshot {
                let plan = Profiles.plan(p, for: game)
                Text((plan.gameSettings + plan.sharedSettings).map { "• " + $0 }.joined(separator: "\n")
                     + (plan.skipped.isEmpty ? "" : "\n\nSkipped: " + plan.skipped.joined(separator: ", "))
                     + "\n\nYou can undo this right after.")
            }
        }
    }

    var placeholder: String {
        switch newKind {
        case .tried: "What did you try? e.g. switched to Compatibility graphics…"
        case .works: "What works? e.g. -opengl fixes the black screen"
        case .crashes: "What breaks? e.g. crashes when alt-tabbing in the menu"
        case .info: "Something you found, e.g. a forum tip or WineHQ entry"
        }
    }

    @ViewBuilder
    func noteRow(_ n: GameNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.kind.symbol).foregroundStyle(color(n.kind)).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if editing == n.id {
                    TextEditor(text: $editText).frame(minHeight: 50, maxHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    HStack {
                        Button("Save") { saveEdit(n) }.keyboardShortcut(.return, modifiers: .command)
                        Button("Cancel") { editing = nil }
                    }
                } else {
                    Text(n.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let l = n.link, !l.isEmpty {
                    if let u = URL(string: l), u.scheme?.hasPrefix("http") == true { Link(l, destination: u).font(.caption).lineLimit(1) }
                    else { Text(l).font(.caption).textSelection(.enabled) }
                }
                HStack(spacing: 6) {
                    Text(n.created.formatted(date: .abbreviated, time: .shortened))
                    if n.edited != nil { Text("· edited") }
                    if let s = n.setup, !s.isEmpty {
                        Button {
                            if expanded.contains(n.id) { expanded.remove(n.id) } else { expanded.insert(n.id) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: expanded.contains(n.id) ? "chevron.down" : "chevron.right").font(.caption2)
                                Text(expanded.contains(n.id) ? "Setup at the time" : s).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.plain).help("Show the setup this note was written with")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if expanded.contains(n.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(setupLines(n), id: \.self) { Text("• " + $0) }
                        if let p = n.snapshot {
                            Button("Restore This Setup…") { restoring = n }.padding(.top, 4)
                                .disabled(Profiles.plan(p, for: game).gameSettings.isEmpty && Profiles.plan(p, for: game).sharedSettings.isEmpty)
                        } else {
                            Text("This note is from before Nokcandu kept full setups, so it can't be restored.").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer()
            Menu {
                Button("Edit") { editing = n.id; editText = n.text }
                if n.snapshot != nil { Button("Restore This Setup…") { restoring = n } }
                Menu("Change Type") {
                    ForEach(GameNote.Kind.allCases) { k in Button(k.title) { update(n.id) { $0.kind = k } } }
                }
                Divider()
                Button("Delete", role: .destructive) { notes.removeAll { $0.id == n.id }; persist() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 30)
        }
        .padding(.vertical, 4)
    }

    func color(_ k: GameNote.Kind) -> Color {
        switch k { case .tried: .blue; case .works: .green; case .crashes: .red; case .info: .purple }
    }

    func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let link = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = GameNote(kind: newKind, text: text, link: link.isEmpty ? nil : link,
                            setup: attachSetup ? GameNotes.currentSetup(game) : nil)
        if attachSetup, game.custom != nil || game.battleNet != nil {
            note.snapshot = Profiles.make(from: game, rating: .playable, notes: nil, install: nil)
        }
        notes.insert(note, at: 0)
        newText = ""; newLink = ""
        persist()
    }

    /// The setup a note was written with, one setting per line.
    func setupLines(_ n: GameNote) -> [String] {
        if let p = n.snapshot {
            var out: [String] = []
            if let g = p.graphics { out.append("Graphics: \(g.title)") }
            if let prog = p.program { out.append("Program: \(prog)") }
            if let a = p.arguments, !a.isEmpty { out.append("Launch options: \(a)") }
            if let a = p.hostArguments, !a.isEmpty { out.append("Battle.net options: \(a)") }
            for (k, v) in (p.environment ?? [:]).sorted(by: { $0.key < $1.key }) { out.append("\(k)=\(v)") }
            if let r = p.rawMouse { out.append(r > 0 ? "Raw mouse: on (\(String(format: "%.2g", r))×\(p.rawMouseSmooth == true ? ", smooth" : ""))" : "Raw mouse: off") }
            if let perf = p.performance {
                out.append("FPS counter: \(perf.fpsCounter ? "on" : "off") · Vsync: \(perf.vsync ? "on" : "off") · Frame limit: \(perf.fpsLimit == 0 ? "off" : "\(perf.fpsLimit) FPS")\(perf.lowLatency == true ? " · Low-latency mode" : "")")
            }
            if let b = p.audioBuffer { out.append("Audio buffer: \(b) ms") }
            if let d = p.displayPixels, d.count == 2 { out.append("Game resolution: \(d[0]) × \(d[1])") }
            if let f = p.fixes, !f.isEmpty { out.append("Fixes: \(f.joined(separator: ", "))") }
            if let dr = p.drives, !dr.isEmpty { out.append("Drives: \(dr.map { "\($0):" }.joined(separator: " "))") }
            return out
        }
        return (n.setup ?? "").components(separatedBy: " · ").filter { !$0.isEmpty }
    }

    func restore(_ n: GameNote) {
        guard let p = n.snapshot else { return }
        do {
            undo = try Profiles.apply(p, to: game, includeShared: true)
            model.refresh()
            model.say("Restored the setup from \(n.created.formatted(date: .abbreviated, time: .shortened)). Press Play to try it.")
        } catch { model.fail(error) }
    }

    func saveEdit(_ n: GameNote) {
        update(n.id) { $0.text = editText; $0.edited = Date() }
        editing = nil
    }

    func update(_ id: GameNote.ID, _ change: (inout GameNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        persist()
    }

    func persist() {
        do { try GameNotes.save(notes, for: game) } catch { model.fail(error) }
    }
}
