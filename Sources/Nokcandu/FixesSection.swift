import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

/// Known, undoable compatibility fixes for a game's Windows environment.
struct FixesSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var present = false
    @State private var working = false
    @State private var log: [String] = []
    @State private var confirmUndo = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "film").font(.title3).foregroundStyle(present ? .green : .secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Fix video and music playback").font(.body.bold())
                            if present { Text("Installed").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule()).foregroundStyle(.green) }
                        }
                        Text("Adds a movie reader, video decoder and audio decoder (LAV Filters \(CinematicFix.version), open source) to \(game.usesSharedSteam ? "the shared Steam's" : "this game's") Windows environment, for games whose videos crash or stay black, or whose MP3 music won't play (“Music Error: Can not play file”). Confirmed to fix Warcraft III's cinematics on this Mac.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if CinematicFix.likelyUsesDirectShow(game) && !present {
                            Label("This game looks like it plays videos through DirectShow, so it may need this.", systemImage: "lightbulb")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    else if present {
                        Button("Undo…") { confirmUndo = true }
                    } else {
                        Button("Install Fix") { install() }
                    }
                }
                if !present && !working {
                    Button("Use Downloaded Zip Instead…") { installFromZip() }.buttonStyle(.link).font(.caption)
                }
                if !log.isEmpty {
                    Text(log.suffix(6).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Fixes").font(.headline) }
        .onAppear { present = CinematicFix.isPresent(for: game) }
        .confirmationDialog("Remove the cinematic fix from \(game.usesSharedSteam ? "the shared Steam" : game.name)?", isPresented: $confirmUndo) {
            Button("Remove", role: .destructive) { undo() }
        } message: { Text("Unregisters the three LAV components and moves their folder to the Trash.") }
    }

    var logger: @Sendable (String) -> Void { { line in Task { @MainActor in log.append(line) } } }

    func install(zips: [CinematicFix.Arch: URL] = [:]) {
        working = true; log = []
        let g = game, l = logger
        Task {
            do {
                try await CinematicFix.install(for: g, localZips: zips, log: l)
                model.say("Cinematic fix installed. Try the game again.")
            } catch { model.fail(error) }
            working = false
            present = CinematicFix.isPresent(for: g)
        }
    }

    func installFromZip() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "zip")].compactMap { $0 }
        p.allowsMultipleSelection = true
        p.message = "Choose LAVFilters-\(CinematicFix.version)-x86.zip and/or -x64.zip from github.com/Nevcairiel/LAVFilters"
        guard p.runModal() == .OK else { return }
        var zips: [CinematicFix.Arch: URL] = [:]
        for u in p.urls {
            if u.lastPathComponent.contains("x64") { zips[.x64] = u } else if u.lastPathComponent.contains("x86") { zips[.x86] = u }
        }
        install(zips: zips)
    }

    func undo() {
        working = true; log = []
        let g = game, l = logger
        Task {
            do { try await CinematicFix.undo(for: g, log: l); model.say("Cinematic fix removed.") } catch { model.fail(error) }
            working = false
            present = CinematicFix.isPresent(for: g)
        }
    }
}

/// Shown at the top of a game page when the last launch ended on a video-playback error.
struct CinematicCrashBanner: View {
    let game: InstalledGame
    let diagnosis: CinematicFix.Diagnosis
    var onFix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "film.stack").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("The last launch stopped while playing a video").font(.body.bold())
                Text("Windows' video playback reported an error\(diagnosis.seconds.map { " after \($0)s" } ?? ""). Installing the cinematic fix usually solves this, and it can be undone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(diagnosis.evidence).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button("Fix Cinematic Playback", action: onFix).buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
