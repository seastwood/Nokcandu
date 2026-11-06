import SwiftUI
import AppKit

/// After an update, this version's release notes once (also in Help → What's New in Nokcandu).
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
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's New in Nokcandu \(WhatsNew.version)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
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

    enum Block { case heading(String), bullet(String), text(String) }
    var blocks: [Block] {
        (WhatsNew.notes ?? "").components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("# ") { return nil }          // the title is the sheet's own
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
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(s).fixedSize(horizontal: false, vertical: true)
            }
        case .text(let s): inline(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
