import SwiftUI
import AppKit
import NokcanduCore

/// After an update, the release notes of every version since the last one seen, once (at most ten versions;
/// Help → What's New in Nokcandu shows this version's).
enum WhatsNew {
    static let key = "whatsNewSeen"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var notes: String? {
        Bundle.main.url(forResource: "WhatsNew", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// True once per new version for someone updating. A brand-new install starts with the welcome instead.
    @MainActor static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        let current = version
        guard !current.isEmpty, notes != nil else { return false }
        let seen = defaults.string(forKey: key)
        if seen == current { return false }
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        if seen == nil && domain.count < 3 { defaults.set(current, forKey: key); return false }   // fresh install
        return true
    }
    static func markSeen() { UserDefaults.standard.set(version, forKey: key) }

    /// Every version's notes that came with this app (Resources/ReleaseNotes/v<version>.md).
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("ReleaseNotes") }
    static func notes(for v: String) -> String? {
        if let f = folder?.appendingPathComponent("v\(v).md"), let s = try? String(contentsOf: f, encoding: .utf8) { return s }
        return v == version ? notes : nil
    }
    /// The versions to show now, newest first, and whether older missed ones were left out.
    static func pending(defaults: UserDefaults = .standard) -> (versions: [String], more: Bool) {
        let names = folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        var available = names.compactMap(ReleaseNotesSelection.version(fileName:))
        if !available.contains(version), notes != nil { available.append(version) }
        let r = ReleaseNotesSelection.missed(available: available, seen: defaults.string(forKey: key), current: version)
        return r.versions.isEmpty ? ([version], false) : r
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    /// Decided when the window opens: closing it marks everything seen.
    @State private var shown = WhatsNew.pending()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shown.versions.count > 1 ? "What's New Since You Last Updated" : "What's New in Nokcandu \(shown.versions.first ?? WhatsNew.version)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shown.versions.enumerated()), id: \.element) { index, version in
                        if shown.versions.count > 1 {
                            if index > 0 { Divider().padding(.vertical, 8) }
                            Text("Nokcandu \(version)").font(.title3.bold())
                        }
                        ForEach(Array(blocks(WhatsNew.notes(for: version) ?? "").enumerated()), id: \.offset) { _, b in block(b) }
                    }
                    if shown.more {
                        Divider().padding(.vertical, 8)
                        Text("Earlier versions are in All Release Notes.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 280, maxHeight: 460)
            HStack {
                if let url = URL(string: "https://github.com/seastwood/Nokcandu/releases") {
                    Link("All Release Notes", destination: url)
                }
                Spacer()
                Button("Continue") { WhatsNew.markSeen(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 600)
        .onDisappear { WhatsNew.markSeen() }
    }

    enum Block { case heading(String), subheading(String), bullet(String), text(String) }
    func blocks(_ notes: String) -> [Block] {
        notes.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("# ") { return nil }          // the title is the sheet's own
            if line.hasPrefix("### ") { return .subheading(String(line.dropFirst(4))) }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .text(line)
        }
    }
    func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }
    @ViewBuilder func block(_ b: Block) -> some View {
        switch b {
        case .heading(let s): Text(s).font(.headline).padding(.top, 6)
        case .subheading(let s): Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(s).fixedSize(horizontal: false, vertical: true)
            }
        case .text(let s): inline(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
