import SwiftUI
import NokcanduCore

/// The sidebar's Profiles tab: controller profiles and keyboard layouts, organised like games. Selecting one
/// shows it on the right. Works with no games at all, for using Nokcandu just for its remapping.
struct ProfilesSidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pad = DesktopPad.shared
    @State private var pads: [PadProfiles.Profile] = []
    @State private var layouts: [KeyRemap.Layout] = []
    @State private var padDefault: String?
    @State private var keysDefault: String?
    @State private var usage: [String: [String]] = [:]       // profile id → game names

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
            Section("On the Mac") {
                row(title: "Controller on the Mac", subtitle: pad.everywhereID != nil || pad.on ? pad.status : "Off — profiles apply only in games", symbol: "desktopcomputer")
                    .tag("mac")
            }
            Section("Controller Profiles") {
                if pads.isEmpty {
                    Text("None yet").foregroundStyle(.secondary).selectionDisabled()
                }
                ForEach(pads) { p in
                    row(title: p.name, subtitle: padSubtitle(p), symbol: "gamecontroller")
                        .tag("pad:" + p.id)
                        .contextMenu { padMenu(p) }
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
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Button("Blank Profile") { newPad(PadProfiles.Profile(name: "New Profile")) }
                    Divider()
                    ForEach(PadProfiles.starters() + [PadProfiles.desktopStarter()]) { s in Button(s.name) { newPad(s) } }
                } label: { Label("New Controller Profile", systemImage: "plus.circle") }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .padding(.leading, 3)          // a menu's label sits 3 points left of a button's
                Button { newLayout() } label: { Label("New Keyboard Layout", systemImage: "plus.circle") }
            }
            .buttonStyle(.borderless)
            .labelStyle(AlignedIconLabelStyle())
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in load() }
        .onChange(of: model.libraryRevision) { _, _ in load() }
    }

    func row(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    func padSubtitle(_ p: PadProfiles.Profile) -> String {
        var parts: [String] = []
        if p.id == padDefault { parts.append("Default") }
        if pad.profileID == p.id { parts.append("Mac") }
        let n = usage[p.id]?.count ?? 0
        if n > 0 { parts.append(n == 1 ? usage[p.id]![0] : "\(n) games") }
        return parts.isEmpty ? "Not in use" : parts.joined(separator: " · ")
    }

    @ViewBuilder func padMenu(_ p: PadProfiles.Profile) -> some View {
        Button("Use on the Mac") { pad.profileID = p.id; pad.on = true }
        Button(p.id == padDefault ? "Stop Using as Default" : "Set as Default for All Games") { ProfileActions.setDefault(p.id == padDefault ? nil : p, model: model) }
        Button(pad.everywhereID == p.id ? "Stop Using Everywhere" : "Use Everywhere") { pad.everywhereID = pad.everywhereID == p.id ? nil : p.id; if pad.everywhereID != nil { pad.enabled = true } }
        Button("Duplicate") { ProfileActions.duplicate(p, model: model) }
        Divider()
        Button("Delete", role: .destructive) { ProfileActions.delete(p, model: model); model.profileSelection = "mac" }
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
        var p = starter
        if !keepName { p.id = UUID().uuidString }
        var n = p.name, i = 2
        while pads.contains(where: { $0.name == n }) { n = "\(starter.name) \(i)"; i += 1 }
        p.name = n
        try? PadProfiles.store(p, environments: [])
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        model.profileSelection = "pad:" + p.id
    }

    func newLayout() {
        var n = "New Layout", i = 2
        while layouts.contains(where: { $0.name == n }) { n = "New Layout \(i)"; i += 1 }
        let l = KeyRemap.Layout(name: n, mappings: [])
        try? KeyRemap.store(l, environments: [])
        load()
        model.profileSelection = "keys:" + l.id
    }
}

enum ProfileActions {
    /// A copy with a free name ("CS2 copy", "CS2 copy 2"…), selected so it can be changed straight away.
    @MainActor static func duplicate(_ p: PadProfiles.Profile, model: AppModel) {
        let names = Set(PadProfiles.profiles().map(\.name))
        var c = p; c.id = UUID().uuidString
        var n = p.name + " copy", i = 2
        while names.contains(n) { n = "\(p.name) copy \(i)"; i += 1 }
        c.name = n
        try? PadProfiles.store(c, environments: [])
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        model.profileSelection = "pad:" + c.id
        model.say("Made \(n). Change it, then choose it on the other game's Controls tab.")
    }
    @MainActor static func setDefault(_ p: PadProfiles.Profile?, model: AppModel) {
        do {
            try PadProfiles.setDefault(p, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
            model.say(p.map { "\($0.name) is the default controller profile: games you haven't given another one use it." } ?? "No default controller profile.")
        } catch { model.fail(error) }
    }
    @MainActor static func delete(_ p: PadProfiles.Profile, model: AppModel) {
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
        if sel.hasPrefix("pad:"), let p = PadProfiles.profiles().first(where: { $0.id == String(sel.dropFirst(4)) }) {
            PadProfilePage(profile: p).id(p.id)
        } else if sel.hasPrefix("keys:"), let l = KeyRemap.layouts().first(where: { $0.id == String(sel.dropFirst(5)) }) {
            KeyLayoutPage(layout: l).id(l.id)
        } else {
            Form { DesktopPadSettings() }.formStyle(.grouped)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(users.isEmpty ? "Not used by any game yet. Choose it on a game's Controls tab, set it as the default, or use it on the Mac."
                                   : "Used by " + ListFormatter.localizedString(byJoining: users) + ".")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(pad.everywhereID == profile.id ? "Stop Using Everywhere" : "Use Everywhere") {
                    pad.everywhereID = pad.everywhereID == profile.id ? nil : profile.id
                    if pad.everywhereID != nil { pad.enabled = true }
                }
                .help("Use this profile in every app and game, until you stop it — for streaming, or trying it anywhere.")
                Button(pad.profileID == profile.id && pad.on ? "Used on the Mac" : "Use on the Mac") { pad.profileID = profile.id; pad.on = true }
                    .disabled(pad.profileID == profile.id && pad.on)
                Button("Duplicate") { ProfileActions.duplicate(profile, model: model) }
                    .help("A copy to change for another game, leaving this one as it is.")
                Button(PadProfiles.defaultID() == profile.id ? "Stop Using as Default" : "Set as Default") {
                    ProfileActions.setDefault(PadProfiles.defaultID() == profile.id ? nil : profile, model: model)
                }
                Button(role: .destructive) { ProfileActions.delete(profile, model: model); model.profileSelection = "mac" } label: { Image(systemName: "trash") }
                    .help("Delete this profile")
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
            try? KeyRemap.store(l, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        }
    }
}
