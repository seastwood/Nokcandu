import UniformTypeIdentifiers
import SwiftUI
import NokcanduCore

/// The sidebar's Profiles tab: controller profiles and keyboard layouts, organised like games. Selecting one
/// shows it on the right. Works with no games at all, for using Nokcandu just for its remapping.
struct ProfilesSidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pad = DesktopPad.shared
    @ObservedObject var devices = ControllerDevices.shared
    @State private var pads: [PadProfiles.Profile] = []
    @State private var layouts: [KeyRemap.Layout] = []
    @State private var padDefault: String?
    @State private var keysDefault: String?
    @State private var usage: [String: [String]] = [:]       // profile id → game names
    @State private var renaming: String?                      // "pad:<id>" or "keys:<id>"
    @State private var renameText = ""

    var body: some View {
        List(selection: $model.profileSelection) {
            Toggle(isOn: $pad.enabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Controller profiles").font(.headline)
                    Text(pad.enabled ? "On — games and apps use their profiles" : "Off — controllers work as they are everywhere").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .selectionDisabled()
            .padding(.vertical, 2)
            Section("Settings") {
                row(title: "Controllers", subtitle: controllersSubtitle, symbol: "gamecontroller.fill")
                    .tag("controllers")
                row(title: "Controller on the Mac", subtitle: pad.everywhereID != nil || pad.on ? pad.status : "Off — profiles apply only in games", symbol: "desktopcomputer")
                    .tag("mac")
                row(title: "Controller Settings", subtitle: "Gyro, notes, capture, headphones", symbol: "slider.horizontal.3")
                    .tag("settings")
            }
            Section("Controller Profiles") {
                if pads.isEmpty {
                    Text("None yet").foregroundStyle(.secondary).selectionDisabled()
                }
                ForEach(pads) { p in
                    row(title: p.name, subtitle: padSubtitle(p), symbol: "gamecontroller", active: pad.activeID == p.id && pad.enabled,
                        icon: ControllerIcon.chosen(p).map { AnyView(ControllerIcon(family: $0)) })
                        .tag("pad:" + p.id)
                }
            }
            Section("Keyboard Layouts") {
                if layouts.isEmpty {
                    Text("None yet").foregroundStyle(.secondary).selectionDisabled()
                }
                ForEach(layouts) { l in
                    row(title: l.name, subtitle: l.id == keysDefault ? "Default for all games" : "\(l.mappings.count) key\(l.mappings.count == 1 ? "" : "s")", symbol: "keyboard")
                        .tag("keys:" + l.id)
                }
            }
        }
        // Right-click any profile or layout.
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                if id.hasPrefix("pad:"), let p = pads.first(where: { $0.id == String(id.dropFirst(4)) }) { padMenu(p) }
                else if id.hasPrefix("keys:"), let l = layouts.first(where: { $0.id == String(id.dropFirst(5)) }) { layoutMenu(l) }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { finishRename() }.disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Games using it keep using it.") }
        .modifier(SidebarFooter {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Button("Blank Profile") { newPad(PadProfiles.Profile(name: "New Profile")) }
                    Divider()
                    ForEach(PadProfiles.starters() + [PadProfiles.desktopStarter(), PadProfiles.steamStarter()]) { s in Button(s.name) { newPad(s) } }
                    Divider()
                    Button("Import from File…") { ProfileActions.importFile(model: model) }
                    Button("Paste Shared Profile") { ProfileActions.importText(NSPasteboard.general.string(forType: .string) ?? "", model: model) }
                    Button("Import Steam Input Layout…") { ProfileActions.importSteamInput(model: model) }
                    Divider()
                    Button("Export All Controller Profiles…") { ProfileActions.exportAll(model: model) }.disabled(pads.isEmpty)
                } label: { Label("New Controller Profile", systemImage: "plus.circle") }
                // Both rows are menus of the same style, so they line up exactly.
                Menu {
                    Button("Blank Layout") { newLayout() }
                    if !layouts.isEmpty {
                        Divider()
                        ForEach(layouts) { l in Button("Copy of \(l.name)") { newLayout(from: l) } }
                    }
                } label: { Label("New Keyboard Layout", systemImage: "plus.circle") }
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .buttonStyle(.borderless)
            .labelStyle(AlignedIconLabelStyle())
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        })
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in load() }
        .onChange(of: model.libraryRevision) { _, _ in load() }
    }

    var controllersSubtitle: String {
        let n = devices.connected.count
        return n == 0 ? "None connected" : n == 1 ? "1 connected" : "\(n) connected"
    }
    func row(title: String, subtitle: String, symbol: String, active: Bool = false, icon: AnyView? = nil) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon { icon } else { Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor) }
            }
            .frame(width: 32, height: 32)
                .overlay(alignment: .bottomTrailing) {
                    if active { Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)).offset(x: 2, y: 2) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(active ? "Active · \(pad.activeWhere)" : subtitle).font(.caption).foregroundStyle(active ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(active ? "Active" : "")
    }

    func padSubtitle(_ p: PadProfiles.Profile) -> String {
        var parts: [String] = []
        if p.id == padDefault { parts.append("Default") }
        if pad.profileID == p.id { parts.append("Mac") }
        let n = usage[p.id]?.count ?? 0
        if n > 0 { parts.append(n == 1 ? usage[p.id]![0] : "\(n) games") }
        // Mac apps set to use it.
        let apps = pad.rules.filter { $0.value == p.id }.keys.sorted()
        if apps.count == 1, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: apps[0]) {
            parts.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        } else if apps.count > 1 { parts.append("\(apps.count) apps") }
        return parts.isEmpty ? "Not in use" : parts.joined(separator: " · ")
    }

    @ViewBuilder func padMenu(_ p: PadProfiles.Profile) -> some View {
        Button(pad.everywhereID == p.id ? "Deactivate" : "Activate Everywhere") {
            pad.everywhereID = pad.everywhereID == p.id ? nil : p.id; if pad.everywhereID != nil { pad.enabled = true }
        }
        Button(pad.profileID == p.id && pad.on ? "Stop Using on the Mac" : "Use on the Mac") {
            if pad.profileID == p.id && pad.on { pad.on = false } else { pad.profileID = p.id; pad.on = true }
        }
        Button(p.id == padDefault ? "Stop Using as Default" : "Set as Default for All Games") { ProfileActions.setDefault(p.id == padDefault ? nil : p, model: model) }
        Divider()
        Button("Edit") { model.profileSelection = "pad:" + p.id }
        Button("Rename…") { renameText = p.name; renaming = "pad:" + p.id }
        Button("Duplicate") { ProfileActions.duplicate(p, model: model) }
        Divider()
        Button("Save as File…") { ProfileActions.export(p, model: model) }
        Button("Export All Controller Profiles…") { ProfileActions.exportAll(model: model) }
        Divider()
        Button("Delete", role: .destructive) { ProfileActions.delete(p, model: model); model.profileSelection = "mac" }
    }

    @ViewBuilder func layoutMenu(_ l: KeyRemap.Layout) -> some View {
        Button(l.id == keysDefault ? "Stop Using as Default" : "Set as Default for All Games") {
            try? KeyRemap.setDefault(l.id == keysDefault ? nil : l, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            load()
        }
        Divider()
        Button("Edit") { model.profileSelection = "keys:" + l.id }
        Button("Rename…") { renameText = l.name; renaming = "keys:" + l.id }
        Button("Duplicate") {
            let names = Set(layouts.map(\.name))
            var n = l.name + " copy", i = 2
            while names.contains(n) { n = "\(l.name) copy \(i)"; i += 1 }
            let c = KeyRemap.Layout(name: n, mappings: l.mappings)
            _ = try? KeyRemap.store(c, environments: [])
            load(); model.profileSelection = "keys:" + c.id
        }
        Divider()
        Button("Delete", role: .destructive) {
            try? KeyRemap.delete(l, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            load(); model.profileSelection = "mac"
        }
    }

    func finishRename() {
        PadProfileEdits.shared.flushAll()
        let n = renameText.trimmingCharacters(in: .whitespaces)
        guard let id = renaming, !n.isEmpty else { return }
        if id.hasPrefix("pad:"), var p = PadProfiles.profiles().first(where: { $0.id == String(id.dropFirst(4)) }) {
            p.name = n
            do { try PadProfiles.store(p, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games)) }
            catch { model.fail(error); return }
        } else if id.hasPrefix("keys:"), var l = layouts.first(where: { $0.id == String(id.dropFirst(5)) }) {
            l.name = n
            _ = try? KeyRemap.store(l, environments: [])
        }
        renaming = nil
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        load()
        // Show the page again with the new name.
        let sel = model.profileSelection
        model.profileSelection = nil
        DispatchQueue.main.async { model.profileSelection = sel }
    }

    func load() {
        pads = PadProfiles.profiles()
        layouts = KeyRemap.layouts()
        padDefault = PadProfiles.defaultID()
        keysDefault = KeyRemap.defaultLayoutID()
        var u: [String: [String]] = [:]
        for g in model.games where !LibraryOrganizer.isLauncher(g) {
            if let p = DesktopPad.profile(for: g, all: pads) { u[p.id, default: []].append(g.name) }
        }
        usage = u
    }

    func newPad(_ starter: PadProfiles.Profile, keepName: Bool = false) {
        PadProfileEdits.shared.flushAll()
        var p = starter
        if !keepName { p.id = UUID().uuidString }
        var n = p.name, i = 2
        while pads.contains(where: { $0.name == n }) { n = "\(starter.name) \(i)"; i += 1 }
        p.name = n
        do { try PadProfiles.store(p, environments: []) }
        catch { model.fail(error); return }
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        model.profileSelection = "pad:" + p.id
    }

    func newLayout(from source: KeyRemap.Layout? = nil) {
        let base = source.map { "\($0.name) copy" } ?? "New Layout"
        var n = base, i = 2
        while layouts.contains(where: { $0.name == n }) { n = "\(base) \(i)"; i += 1 }
        let l = KeyRemap.Layout(name: n, mappings: source?.mappings ?? [])
        _ = try? KeyRemap.store(l, environments: [])
        load()
        model.profileSelection = "keys:" + l.id
    }
}

enum ProfileActions {
    /// A copy with a free name ("CS2 copy", "CS2 copy 2"…), selected so it can be changed straight away.
    @MainActor static func duplicate(_ p: PadProfiles.Profile, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let p = PadProfiles.profiles().first { $0.id == p.id } ?? p
        let names = Set(PadProfiles.profiles().map(\.name))
        var c = p; c.id = UUID().uuidString
        var n = p.name + " copy", i = 2
        while names.contains(n) { n = "\(p.name) copy \(i)"; i += 1 }
        c.name = n
        do { try PadProfiles.store(c, environments: []) }
        catch { model.fail(error); return }
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        model.profileSelection = "pad:" + c.id
        model.say("Made \(n). Change it, then choose it on the other game's Controls tab.")
    }
    @MainActor static func copy(_ p: PadProfiles.Profile, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let p = PadProfiles.profiles().first { $0.id == p.id } ?? p
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PadProfiles.exportText(p, all: PadProfiles.profiles()), forType: .string)
        model.say("Copied \(p.name). Paste it into a message; the other person chooses New Controller Profile → Paste Shared Profile.")
    }
    /// A link that carries the whole profile: whoever opens it on a Mac with Nokcandu is asked to add it.
    @MainActor static func copyLink(_ p: PadProfiles.Profile, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let p = PadProfiles.profiles().first { $0.id == p.id } ?? p
        guard let url = PadProfileLink.make(PadProfiles.exportText(p, all: PadProfiles.profiles())) else { model.say("Couldn't make a link for \(p.name)."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        model.say("Copied a link to \(p.name). Opening it on a Mac with Nokcandu offers to add the profile; nothing is uploaded.")
    }
    /// A profile link was opened: ask, then add it as a copy.
    @MainActor static func openLink(_ url: URL, model: AppModel) {
        guard let text = PadProfileLink.text(url), let list = try? PadProfiles.parseShared(text), let first = list.first else {
            model.say("That profile link is damaged or isn't a Nokcandu controller profile."); return
        }
        let alert = NSAlert()
        alert.messageText = "Add the controller profile “\(first.name)”?"
        let notes = PadProfileImportReview.notes(list)
        alert.informativeText = (list.count > 1 ? "It comes with \(list.count - 1) profile\(list.count == 2 ? "" : "s") it builds on. They're added as new profiles; nothing here is changed." : "It's added as a new profile; nothing here is changed.")
            + (notes.isEmpty ? "" : "\n\nAdd it only if you trust where the link came from. It:\n• " + notes.joined(separator: "\n• "))
        if !notes.isEmpty { alert.alertStyle = .warning }
        alert.addButton(withTitle: "Add Profile"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        importText(text, model: model, reviewed: true)
    }
    @MainActor static func export(_ p: PadProfiles.Profile, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let p = PadProfiles.profiles().first { $0.id == p.id } ?? p
        let panel = NSSavePanel()
        panel.nameFieldStringValue = p.name + ".nokpad.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(PadProfiles.exportText(p, all: PadProfiles.profiles()).utf8).write(to: url, options: .atomic); model.say("Saved \(p.name) as \(url.lastPathComponent).") }
        catch { model.fail(error) }
    }
    /// Every controller profile, one file each, in a zip: a backup, or to move or share them all at once.
    @MainActor static func exportAll(model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let all = PadProfiles.profiles()
        guard !all.isEmpty else { model.say("There are no controller profiles to export yet."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PadProfiles.archiveName
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PadProfiles.exportArchive(all, all: all, to: url)
            model.say("Saved \(all.count) controller profile\(all.count == 1 ? "" : "s") in \(url.lastPathComponent). To bring them back, or into Nokcandu on another Mac, drop the zip (or any one file from it) on Nokcandu.")
        } catch { model.fail(error) }
    }
    @MainActor static func importFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .zip]
        panel.allowsMultipleSelection = true
        panel.message = "Choose controller profile files, or a zip of them."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls, model: model)
    }
    /// Profile files, zips of them or folders of them (chosen, or dropped on the window).
    @MainActor static func importFiles(_ urls: [URL], model: AppModel) {
        PadProfileEdits.shared.flushAll()
        do { finishImport(try PadProfiles.importFiles(urls, existing: PadProfiles.profiles()), model: model) }
        catch { model.fail(error) }
    }
    @MainActor static func importText(_ text: String, model: AppModel, reviewed: Bool = false) {
        PadProfileEdits.shared.flushAll()
        do {
            let merged = PadProfiles.merge([try PadProfiles.parseShared(text)], existing: PadProfiles.profiles(), skipIdentical: true)
            finishImport(PadProfiles.Imported(added: merged.added, alreadyHere: merged.alreadyHere), model: model, reviewed: reviewed)
        } catch { model.fail(error) }
    }
    /// Before adding profiles from a file or link: what they'd type or press that's worth a second look.
    @MainActor static func confirmReview(_ profiles: [PadProfiles.Profile]) -> Bool {
        let notes = PadProfileImportReview.notes(profiles)
        guard !notes.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = profiles.count == 1 ? "Add “\(profiles[0].name)”?" : "Add \(profiles.count) controller profiles?"
        alert.informativeText = "Add only profiles you trust. They:\n• " + notes.joined(separator: "\n• ")
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// A Steam Input layout (.vdf) as a new profile: Steam keeps each game's in Steam Controller Configs, and
    /// community layouts too. What couldn't come across is listed afterwards.
    @MainActor static func importSteamInput(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vdf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Steam Input layout (.vdf). Steam keeps each game's in Steam Controller Configs, in a folder named for the game's number."
        let configs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/steamapps/common/Steam Controller Configs")
        if FileManager.default.fileExists(atPath: configs.path) { panel.directoryURL = configs }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // A game's layout sits in a folder named for its Steam app number.
            let folder = url.deletingLastPathComponent().lastPathComponent
            let fallback = Int(folder) != nil ? "Steam layout (app \(folder))" : url.deletingPathExtension().lastPathComponent
            let r = try SteamInputImport.profile(fromVDF: text, fallbackName: fallback)
            let merged = PadProfiles.merge([[r.profile]], existing: PadProfiles.profiles(), skipIdentical: false)
            finishImport(PadProfiles.Imported(added: merged.added, alreadyHere: merged.alreadyHere), model: model)
            if !r.notes.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Imported “\(r.profile.name)”"
                alert.informativeText = "Some of the layout works differently here or couldn't come across:\n\n• " + r.notes.joined(separator: "\n• ")
                alert.runModal()
            }
        } catch { model.fail(error) }
    }
    @MainActor private static func finishImport(_ result: PadProfiles.Imported, model: AppModel, reviewed: Bool = false) {
        if !reviewed, !result.added.isEmpty, !confirmReview(result.added) { return }
        do {
            for p in result.added { try PadProfiles.store(p, environments: []) }
        } catch { model.fail(error); return }
        if !result.added.isEmpty { NotificationCenter.default.post(name: .padProfilesChanged, object: nil) }
        if let last = result.added.last { model.profileSelection = "pad:" + last.id }
        var parts: [String] = []
        if result.added.count == 1 { parts.append("Added \(result.added[0].name).") }
        else if result.added.count > 1 { parts.append("Added \(result.added.count) controller profiles.") }
        if !result.alreadyHere.isEmpty {
            parts.append(result.alreadyHere.count == 1 ? "\(result.alreadyHere[0]) is already here, unchanged." : "\(result.alreadyHere.count) are already here, unchanged.")
        }
        if !result.unreadable.isEmpty { parts.append("Not controller profiles: \(result.unreadable.joined(separator: ", ")).") }
        if result.added.isEmpty && result.alreadyHere.isEmpty { model.fail(NokError("That isn't a Nokcandu controller profile.")) }
        else { model.say(parts.joined(separator: " ")) }
    }
    @MainActor static func setDefault(_ p: PadProfiles.Profile?, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        do {
            try PadProfiles.setDefault(p, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
            model.say(p.map { "\($0.name) is the default controller profile: games you haven't given another one use it." } ?? "No default controller profile.")
        } catch { model.fail(error) }
    }
    @MainActor static func delete(_ p: PadProfiles.Profile, model: AppModel) {
        PadProfileEdits.shared.flushAll()
        let p = PadProfiles.profiles().first { $0.id == p.id } ?? p
        do {
            try PadProfiles.delete(p, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            if DesktopPad.shared.profileID == p.id { DesktopPad.shared.profileID = nil }
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
            model.say("Deleted \(p.name). Games that chose it keep a copy as their own.")
        } catch { model.fail(error) }
    }
}

/// The right side of the Profiles tab.
struct ProfilesTabDetail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sel = model.profileSelection ?? "mac"
        Group {
            if sel.hasPrefix("pad:"), let p = PadProfiles.profiles().first(where: { $0.id == String(sel.dropFirst(4)) }) {
                PadProfilePage(profile: p).id(p.id + p.name)          // a rename from the sidebar reloads the editor
            } else if sel.hasPrefix("keys:"), let l = KeyRemap.layouts().first(where: { $0.id == String(sel.dropFirst(5)) }) {
                KeyLayoutPage(layout: l).id(l.id + l.name)
            } else if sel == "controllers" {
                ControllersPanel()
            } else if sel == "settings" {
                // Everything about controllers that isn't one profile: in games, on the Mac and in streams.
                Form {
                    ControllerOwnershipSettings()
                    PadDSUSettings()
                    PadGyroAndNotesSettings()
                    ControllerOverlaySettingsView()
                    PadCaptureSettings()
                    PadHeadTrackingSettings()
                    PadDiagnosticsSettings()
                }.formStyle(.grouped)
            } else {
                Form { DesktopPadSettings() }.formStyle(.grouped)
            }
        }
    }
}

struct PadProfilePage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pad = DesktopPad.shared
    let profile: PadProfiles.Profile

    var users: [String] {
        let all = PadProfiles.profiles()
        return model.games.filter { !LibraryOrganizer.isLauncher($0) && DesktopPad.profile(for: $0, all: all)?.id == profile.id }.map(\.name).sorted()
    }

    var isDefault: Bool { PadProfiles.defaultID() == profile.id }
    func toggleDefault() { ProfileActions.setDefault(isDefault ? nil : profile, model: model) }
    func remove() { ProfileActions.delete(profile, model: model); model.profileSelection = "mac" }

    var usage: some View {
        Text(users.isEmpty ? "Not used by any game yet. Choose it on a game's Controls tab, set it as the default, or use it on the Mac."
                           : "Used by " + ListFormatter.localizedString(byJoining: users) + ".")
            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            .frame(minWidth: 200, alignment: .leading)
    }
    var everywhereButton: some View {
        Button(pad.everywhereID == profile.id ? "Stop Using Everywhere" : "Use Everywhere") {
            pad.everywhereID = pad.everywhereID == profile.id ? nil : profile.id
            if pad.everywhereID != nil { pad.enabled = true }
        }
        .fixedSize()
        .help("Use this profile in every app and game, until you stop it — for streaming, or trying it anywhere.")
    }
    var macButton: some View {
        Button(pad.profileID == profile.id && pad.on ? "Used on the Mac" : "Use on the Mac") { pad.profileID = profile.id; pad.on = true }
            .disabled(pad.profileID == profile.id && pad.on).fixedSize()
    }
    @ViewBuilder var shareItems: some View {
        Button("Copy to Clipboard") { ProfileActions.copy(profile, model: model) }
        Button("Save as File…") { ProfileActions.export(profile, model: model) }
        Button("Copy Link") { ProfileActions.copyLink(profile, model: model) }
    }
    var moreMenu: some View {
        Menu {
            Button("Duplicate") { ProfileActions.duplicate(profile, model: model) }
            Menu("Share") { shareItems }
            Button(isDefault ? "Stop Using as Default" : "Set as Default") { toggleDefault() }
            Divider()
            Button("Delete Profile", role: .destructive) { remove() }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden).fixedSize()
        .help("Duplicate, share, set as the default or delete this profile")
        .accessibilityLabel("More profile actions")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Everything on one line while it fits; otherwise the less-used actions fold into a menu.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    usage
                    Spacer(minLength: 8)
                    everywhereButton; macButton
                    Button("Duplicate") { ProfileActions.duplicate(profile, model: model) }
                        .help("A copy to change for another game, leaving this one as it is.")
                    Menu("Share") { shareItems }
                        .fixedSize()
                        .help("Send this profile to someone: they add it with New Controller Profile → Import.")
                    Button(isDefault ? "Stop Using as Default" : "Set as Default") { toggleDefault() }
                    Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                        .help("Delete this profile")
                }
                HStack(spacing: 10) {
                    usage
                    Spacer(minLength: 8)
                    everywhereButton; macButton; moreMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    usage
                    HStack(spacing: 10) { everywhereButton; macButton; moreMenu; Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
            ControllerProfileEditor(profile: profile, own: false, gameName: "", all: PadProfiles.profiles(), embedded: true) { p in
                do {
                    try PadProfiles.store(p, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
                    NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
                } catch { model.fail(error) }
            }
        }
    }
}

/// A keyboard layout: keys that act as other keys while a game using it is in front.
struct KeyLayoutPage: View {
    @EnvironmentObject var model: AppModel
    @State var layout: KeyRemap.Layout

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $layout.name)
                Toggle("Default for all games", isOn: Binding(get: { KeyRemap.defaultLayoutID() == layout.id }, set: { on in
                    try? KeyRemap.setDefault(on ? layout : nil, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
                    model.objectWillChange.send()
                }))
            } header: {
                InspectorTitle(title: layout.name, subtitle: "Keyboard layout", symbol: "keyboard")
            } footer: {
                Text("Games following the default use it unless you choose something else on their Controls tab. Switching to another app puts your keyboard back.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Keys") {
                ForEach(layout.mappings) { m in
                    HStack {
                        Picker("Key", selection: Binding(get: { m.from }, set: { new in
                            guard !layout.mappings.contains(where: { $0.from == new }), let i = layout.mappings.firstIndex(of: m) else { return }
                            layout.mappings[i].from = new
                        })) { ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) } }
                            .labelsHidden().frame(width: 170)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("Acts as", selection: Binding(get: { m.to ?? -1 }, set: { v in
                            guard let i = layout.mappings.firstIndex(of: m) else { return }
                            layout.mappings[i].to = v < 0 ? nil : v
                        })) {
                            Text("Nothing").tag(-1)
                            ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) }
                        }.labelsHidden().frame(width: 170)
                        Spacer()
                        Button { layout.mappings.removeAll { $0.from == m.from } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Key") {
                    let used = Set(layout.mappings.map(\.from))
                    if let free = KeyRemap.keys.first(where: { !used.contains($0.code) }) { layout.mappings.append(KeyRemap.Mapping(from: free.code, to: free.code == 59 ? 62 : 59)) }
                }
            }
            Section {
                Button("Delete Layout", role: .destructive) {
                    try? KeyRemap.delete(layout, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
                    model.profileSelection = "mac"
                    NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: layout) { _, l in
            _ = try? KeyRemap.store(l, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        }
    }
}

/// A profile's controller, small: the outline of the controller its labels are set to (the same outlines as the
/// overlay and the editor), with its sticks or trackpads as dots.
struct ControllerIcon: View {
    let family: Controllers.Family?
    var body: some View {
        let body: AnyShape = {
            switch family {
            case .valve: return AnyShape(Steam2015Outline(points: OverlayLayout.steam2015Body))
            case .steam2026: return AnyShape(Steam2026IconShape())
            default: return AnyShape(LayoutOutlineShape(layout: ControllerPictureLayout.of(family)))
            }
        }()
        let w: CGFloat = 30, h: CGFloat = 21
        ZStack {
            body.fill(Color.accentColor.opacity(0.22))
            body.stroke(Color.accentColor, lineWidth: 1.2)
            // What tells them apart at this size: the pads, the touchpad, where the sticks sit.
            ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                Group {
                    if m.square { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor) }
                    else { Circle().fill(Color.accentColor) }
                }
                .frame(width: m.rect.width * w, height: m.rect.height * h)
                .position(x: m.rect.midX * w, y: m.rect.midY * h)
            }
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }
}

extension ControllerIcon {
    /// The controller a profile's labels are set to; nil when none is chosen (the list then shows a generic
    /// controller). "xbox" is stored for Xbox, which the labels otherwise treat as no family.
    static func chosen(_ p: PadProfiles.Profile) -> Controllers.Family?? {
        guard let saved = p.controllerLabels, !saved.isEmpty else { return nil }
        if saved == "xbox" { return .some(nil) }
        guard let f = Controllers.Family(rawValue: saved) else { return nil }
        return .some(f)
    }

    struct Mark { var rect: CGRect; var square = false }
    /// Fractions of the icon's box (y down).
    var marks: [Mark] {
        func dot(_ c: CGPoint, _ d: CGFloat) -> Mark { Mark(rect: CGRect(x: c.x - d / 2, y: c.y - d * 0.72, width: d, height: d * 1.43)) }
        switch family {
        case .valve:
            return [dot(Steam2015Outline.place(-1.117, 0.242), 0.2), dot(Steam2015Outline.place(1.117, 0.242), 0.2)]
        case .steam2026:
            return [Mark(rect: CGRect(x: 0.23, y: 0.47, width: 0.15, height: 0.2), square: true), Mark(rect: CGRect(x: 0.62, y: 0.47, width: 0.15, height: 0.2), square: true),
                    dot(CGPoint(x: 0.35, y: 0.27), 0.1), dot(CGPoint(x: 0.65, y: 0.27), 0.1)]
        default:
            let l = ControllerPictureLayout.of(family)
            var m = l.sticks.map { dot($0, 0.13) }
            if let t = l.touchpad { m.append(Mark(rect: t.insetBy(dx: 0.03, dy: 0.04), square: true)) }
            return m
        }
    }
}

/// The Steam Controller (2026)'s outline from the editor's picture, fitted to the box.
struct Steam2026IconShape: Shape {
    func path(in r: CGRect) -> Path { Path(Steam2026PictureGeometry.shellPath(in: r)) }
}
