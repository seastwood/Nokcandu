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
                    if let s = n.setup, !s.isEmpty { Text("· \(s)").lineLimit(1).truncationMode(.tail).help(s) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Edit") { editing = n.id; editText = n.text }
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
        notes.insert(GameNote(kind: newKind, text: text, link: link.isEmpty ? nil : link,
                              setup: attachSetup ? GameNotes.currentSetup(game) : nil), at: 0)
        newText = ""; newLink = ""
        persist()
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
