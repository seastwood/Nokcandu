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
        SettingsSection(title: "Fixes") {
            SettingRow(title: "Video and music playback",
                       info: "Adds a movie reader, video decoder and audio decoder (LAV Filters \(CinematicFix.version), open source) to \(CompatibilityFixes.hasSharedEnvironment(game) ? "the shared launcher's" : "this game's") Windows environment, for games whose videos crash or stay black, or whose MP3 music won't play (“Music Error: Can not play file”). Confirmed to fix Warcraft III's cinematics.") {
                if working { ProgressView().controlSize(.small) }
                else if present {
                    InstalledBadge()
                    Button("Undo…") { confirmUndo = true }
                } else {
                    Menu("Install") {
                        Button("Install Fix") { install() }
                        Button("Use Downloaded Zip Instead…") { installFromZip() }
                    } primaryAction: { install() }
                    .fixedSize()
                }
            }
            if CinematicFix.likelyUsesDirectShow(game) && !present {
                SettingNote("This game looks like it plays videos through DirectShow, so it may need this.", warning: true)
            }
            ComponentFixesView(game: game)
            PhysXRuntimeRow(game: game).id("physx-\(game.id)")
            if !log.isEmpty {
                Text(log.suffix(6).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { present = CinematicFix.isPresent(for: game) }
        .confirmationDialog("Remove the cinematic fix from \(CompatibilityFixes.hasSharedEnvironment(game) ? "the shared Windows environment" : game.name)?", isPresented: $confirmUndo) {
            Button("Remove", role: .destructive) { undo() }
        } message: { Text("Unregisters the three LAV components and moves their folder to the Trash.") }
    }

    var logger: @Sendable (String) -> Void { { line in Task { @MainActor in log.append(line) } } }

    func install(zips: [CinematicFix.Arch: URL] = [:]) {
        working = true; log = []
        let g = game, l = logger
        model.changeSetting(for: g, title: "Video Playback Fix", success: "Cinematic fix installed.", change: .cinematic(undo: false, zips: Dictionary(uniqueKeysWithValues: zips.map { ($0.key.rawValue, $0.value.path) })), completion: { _ in working = false; present = CinematicFix.isPresent(for: g) })
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
        model.changeSetting(for: g, title: "Video Playback Fix", success: "Cinematic fix removed.", change: .cinematic(undo: true, zips: [:]), completion: { _ in working = false; present = CinematicFix.isPresent(for: g) })
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

/// App-owned fixes share one operation slot so installs and Undo cannot race within this view.
private struct ComponentFixesView: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var working: CompatibilityFix?
    @State private var installed: Set<String> = []
    @State private var status = ""
    @State private var nativeIPXFrame = 3
    @State private var nativeIPXAdapter = ""
    @State private var nativeIPXAdapters: [NativeIPXNetworking.NetworkAdapter] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if CompatibilityFixes.hasSharedEnvironment(game) {
                SettingRow(title: "Program for fixes", info: "Compatibility fixes belong to this game's registered folder and program. Choosing here does not change what the launcher starts.") {
                    Text(CompatibilityFixes.programForFixes(game)?.lastPathComponent ?? "Choose a program")
                        .font(.caption.monospaced()).lineLimit(1)
                    Button("Choose…") { chooseProgramForFixes() }.disabled(working != nil)
                }
                SettingNote("Game-specific fixes do not change the shared launcher's graphics or other games. Changes wait until its Windows programs close.")
            }
            ForEach(CompatibilityFix.allCases.filter { CompatibilityFixes.visible($0, for: game) }) { fix in
                let on = installed.contains(fix.id)
                let reason = on ? nil : CompatibilityFixes.unavailable(fix, for: game)
                SettingRow(title: fix.title, info: fix.detail + (reason.map { "\n\n" + $0 } ?? "")) {
                    if working == fix { ProgressView().controlSize(.small) }
                    else {
                        if on {
                            if CompatibilityFixes.needsRecovery(fix, for: game) { Text("Needs recovery").font(.caption).foregroundStyle(.orange) }
                            else { InstalledBadge() }
                        }
                        if on, CompatibilityFixes.needsUpdate(fix, for: game) {
                            Button("Update") { run(fix, update: true) }.disabled(working != nil)
                        }
                        Button(on ? "Undo" : (fix == .openUA ? "Apply" : "Install")) { run(fix) }
                            .disabled(working != nil || reason != nil)
                    }
                }
                if fix == .nativeIPXNetworking, on {
                    SettingRow(title: "IPX LAN connection", info: "Choose this Mac’s connection to the other IPX computers. This choice stays on this Mac; shared profiles choose their own local adapter.") {
                        Picker("LAN connection", selection: Binding(get: { nativeIPXAdapter }, set: { setNativeAdapter($0) })) {
                            ForEach(nativeIPXAdapters) { adapter in Text(adapter.title).tag(adapter.id) }
                        }.labelsHidden().disabled(working != nil)
                    }
                    SettingRow(title: "IPX frame type", info: "Match the original computers on your LAN. Windows 98 commonly uses 802.2. This choice is saved in profiles; the local network adapter is not.") {
                        Picker("Frame type", selection: Binding(get: { nativeIPXFrame }, set: { setNativeFrame($0) })) {
                            Text("802.2 (Windows 98)").tag(3)
                            Text("802.3").tag(2)
                            Text("Ethernet II").tag(1)
                        }.labelsHidden().disabled(working != nil)
                    }
                }
                if fix == .ipxNetworking, on {
                    Button("IPX Network Settings…") {
                        do { try IPXNetworking.configure(game) } catch { model.fail(error) }
                    }.disabled(working != nil)
                }
            }
            Link("Microsoft DirectX download and license information", destination: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109")!).font(.caption)
            if !status.isEmpty { SettingNote(status) }
        }
        .onAppear { reload() }
        .onChange(of: game) { reload() }
    }
    func chooseProgramForFixes() {
        let panel = NSOpenPanel()
        panel.directoryURL = CompatibilityFixes.folderForFixes(game)
        panel.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
        panel.message = "Choose this game's Windows program for compatibility fixes. Its launch program stays unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CompatibilityFixes.selectProgramForFixes(url, for: game)
            reload(); model.refresh()
        } catch { model.fail(error) }
    }
    func reload() {
        installed = Set(CompatibilityFixes.installedIDs(for: game))
        nativeIPXFrame = PendingSettings.nativeFrame(for: game) ?? NativeIPXNetworking.frame(for: game) ?? 3
        nativeIPXAdapter = PendingSettings.nativeAdapter(for: game) ?? game.custom?.environment?["NOKCANDU_NATIVE_IPX_INTERFACE"] ?? ""
        nativeIPXAdapters = installed.contains(CompatibilityFix.nativeIPXNetworking.id) ? NativeIPXNetworking.availableAdapters() : []
    }
    func setNativeAdapter(_ name: String) {
        working = .nativeIPXNetworking
        model.changeSetting(for: game, title: "IPX LAN connection", success: "Native IPX connection updated.", change: .nativeAdapter(name), completion: { _ in reload(); working = nil })
    }
    func setNativeFrame(_ frame: Int) {
        working = .nativeIPXNetworking
        model.changeSetting(for: game, title: "IPX frame type", success: "Native IPX frame updated.", change: .nativeFrame(frame), completion: { _ in reload(); working = nil })
    }
    func run(_ fix: CompatibilityFix, update: Bool = false) {
        working = fix; status = ""
        let undo = installed.contains(fix.id) && !update, g = game
        let logger: @Sendable (String) -> Void = { line in Task { @MainActor in status = line } }
        model.changeSetting(for: g, title: fix.title, success: undo ? "Removed \(fix.title)." : "Installed \(fix.title).", change: .compatibility(fix, undo: undo), completion: { _ in reload(); working = nil })
    }
}


/// "Installed" capsule next to a fix's Undo button.
struct InstalledBadge: View {
    var body: some View {
        Text("Installed").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
    }
}
