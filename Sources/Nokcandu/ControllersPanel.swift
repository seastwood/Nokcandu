// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NokcanduCore

/// Profiles → Controllers: every controller connected or remembered, what it's pressing, a buzz to find it, and
/// which player it is and what it gets, in plain words.
struct ControllersPanel: View {
    @ObservedObject private var devices = ControllerDevices.shared
    @ObservedObject private var pad = DesktopPad.shared
    @State private var profiles = PadProfiles.profiles()

    var remembered: [ControllerRoster.Remembered] {
        devices.roster.controllers.filter { r in !devices.connected.contains { $0.key == r.key } }.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        Form {
            Section {
                if devices.connected.isEmpty {
                    Text("No controller connected. Pair one in System Settings → Bluetooth, or plug it in.").foregroundStyle(.secondary)
                }
                ForEach(devices.connected) { c in ControllerRow(connected: c, profiles: profiles) }
            } header: { Text("Connected") } footer: {
                Text("Press a button to see which row lights up, or Ping a controller to make it buzz. Auto controllers take the next free player in the order they connect. Several controllers on the same player drive it together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !remembered.isEmpty {
                Section("Not connected") {
                    ForEach(remembered) { r in RememberedRow(remembered: r, profiles: profiles) }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Which profile a controller gets, first match wins:").font(.callout.weight(.medium))
                    Text("1. A profile used everywhere\n2. In a game: the game's choice for this controller, then the game's profile\n3. In other apps: the app's rule, then this controller's own profile (with “Use a controller profile on the Mac” on), then the Mac's profile")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("A game's choices for particular controllers are in its Controls tab. On the Mac, everything not set to another player drives player 1; Mac games get players 2 and up as they are.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices.start(); devices.refresh(); devices.watch(true); profiles = PadProfiles.profiles() }
        .onDisappear { devices.watch(false) }
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in profiles = PadProfiles.profiles() }
    }
}

private struct ControllerRow: View {
    let connected: ControllerDevices.Connected
    let profiles: [PadProfiles.Profile]
    @ObservedObject private var devices = ControllerDevices.shared
    @ObservedObject private var pad = DesktopPad.shared
    @State private var name = ""
    @State private var pingFailed = false

    var remembered: ControllerRoster.Remembered? { devices.remembered(connected.key) }
    var held: [String] { devices.held[connected.key] ?? [] }
    var active: Bool { !held.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: connected.kind.symbol).font(.title2).foregroundStyle(active ? Color.accentColor : .secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remembered?.name ?? connected.name).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    pingFailed = !devices.ping(connected.key)
                } label: { Label("Ping", systemImage: "waveform.path") }
                .disabled(!devices.canPing(connected.key))
                .help(devices.canPing(connected.key) ? "A soft buzz on this controller" : devices.needsPress(connected.key) ? "Press a button on it first, to tell it apart from the other \(connected.name)" : "This controller can't buzz; press a button to see its row light up")
            }
            // What it's pressing now.
            HStack(spacing: 4) {
                if held.isEmpty {
                    Text(devices.needsPress(connected.key) ? "Press a button on it to tell it apart from the other \(connected.name)" : "Press a button…")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(held, id: \.self) { l in
                        Text(l).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
            }.frame(minHeight: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(devices.macLine(connected.key, profiles: profiles)).font(.callout)
                Text(devices.windowsLine(connected.key)).font(.callout)
            }
            .textSelection(.enabled)
            HStack {
                TextField("Name", text: $name, prompt: Text(connected.name))
                    .onSubmit { devices.rename(connected.key, name) }
                    .frame(maxWidth: 200)
                Picker("Player", selection: Binding(get: { remembered?.seat ?? .auto }, set: { devices.setSeat(connected.key, $0) })) {
                    Text("Auto").tag(ControllerRoster.Seat.auto)
                    ForEach(1...8, id: \.self) { n in Text("Player \(n)").tag(ControllerRoster.Seat.player(n)) }
                }.frame(maxWidth: 170)
                Picker("Own profile", selection: Binding(get: { remembered?.fallbackProfileID ?? devices.ownProfile(connected) ?? "" },
                                                         set: { devices.setFallback(connected.key, $0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(profiles) { p in Text(p.name).tag(p.id) }
                }
                .help("Used in apps and games with no profile of their own choosing (on the Mac, with “Use a controller profile on the Mac” on).")
            }
            if remembered?.byOrder == true && connected.vendorID != 0 && hasTwin {
                Text("It has no serial number Nokcandu can read, so two of this model are told apart by the order they connected; reconnected the other way round, they trade places.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if pingFailed { Text("It didn't buzz. Press a button on it instead.").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(active ? 0.08 : 0)).padding(-4))
        .animation(.easeOut(duration: 0.15), value: active)
        .onAppear { name = remembered?.customName ?? "" }
        .onChange(of: name) { _, n in if n != (remembered?.customName ?? "") { devices.rename(connected.key, n) } }
    }

    /// Another controller of the same model is remembered: only then can the order matter.
    var hasTwin: Bool {
        devices.roster.controllers.contains { $0.key != connected.key && $0.vendorID == connected.vendorID && $0.productID == connected.productID }
    }
    var subtitle: String {
        var parts: [String] = []
        if remembered?.customName != nil { parts.append(connected.name) }
        if let b = connected.bluetooth { parts.append(b ? "Bluetooth" : "USB") }
        parts.append(String(format: "%04X:%04X", connected.vendorID, connected.productID))
        return parts.joined(separator: " · ")
    }
}

private struct RememberedRow: View {
    let remembered: ControllerRoster.Remembered
    let profiles: [PadProfiles.Profile]
    @ObservedObject private var devices = ControllerDevices.shared

    var body: some View {
        HStack {
            Image(systemName: "gamecontroller").foregroundStyle(.tertiary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(remembered.name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget") { devices.forget(remembered.key) }
                .help("Forgets its name, player and profile. It's remembered again, with none, the next time it connects.")
        }
    }
    var summary: String {
        var parts = [remembered.seat.title]
        if let id = remembered.fallbackProfileID, let p = profiles.first(where: { $0.id == id }) { parts.append("own profile \(p.name)") }
        parts.append("last seen " + remembered.lastSeen.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

extension ControllerDevices {
    /// What a controller does on the Mac, in the last game or app used (not Nokcandu itself), and why.
    func macLine(_ key: String, profiles: [PadProfiles.Profile]) -> String {
        let pad = DesktopPad.shared
        guard pad.enabled else { return "Mac: controller profiles are off" }
        if let n = roster.controller(key)?.seat.explicit, n > 1 { return "Mac: Player \(n) — Mac games get it as it is" }
        guard let ctx = pad.lastContext else { return "Mac: Player 1" }
        let choice = ctx.game?.contents.flatMap { PadProfiles.controllerChoices(contents: $0)[key] }
        let own = connected.first { $0.key == key }.flatMap { ownProfile($0) }
        let r = ControllerRoster.resolve(everywhere: ctx.everywhere, game: ctx.game?.name, gameForController: choice, gameProfile: ctx.game?.profileID,
                                         appName: ctx.appName, appRule: ctx.appRule, controllerFallback: ctx.macOn ? own : nil, macDefault: ctx.macDefault)
        let place = ctx.game?.name ?? ctx.appName ?? "the Mac"
        let name = r.id.flatMap { id in profiles.first { $0.id == id }?.name }
        return "In \(place): Player 1 · " + (name.map { "profile \($0)" } ?? "no profile") + " (\(r.reason.words))"
    }
    /// The player a controller is in Windows games.
    func windowsLine(_ key: String) -> String {
        guard connected.first(where: { $0.key == key })?.kind == .gamepad else { return "Windows games: as it is (not a gamepad)" }
        let (n, reported) = windowsPlayer(key)
        let set = roster.controller(key)?.seat.explicit != nil
        return "Windows games: Player \(n)" + (reported ? " in the game running now" : set ? "" : " (Auto)")
    }
}
