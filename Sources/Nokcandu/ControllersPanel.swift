// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NokcanduCore

/// Profiles → Controllers: every controller connected or remembered, what it's pressing, a buzz to find it, and
/// which player it is and what it gets, in plain words.
struct ControllersPanel: View {
    @ObservedObject private var devices = ControllerDevices.shared
    @ObservedObject private var pad = DesktopPad.shared
    @State private var profiles = PadProfiles.profiles()
    @State private var showOrder = false

    var remembered: [ControllerRoster.Remembered] {
        devices.roster.controllers.filter { r in !devices.connected.contains { $0.key == r.key } }.sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Controllers").font(.title2.weight(.semibold))
                    Text("Press a button to see which controller is which, or Ping one to make it buzz. Auto controllers take the next free player in the order they connect; several on the same player drive it together.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            if devices.connected.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller").font(.title).foregroundStyle(.tertiary)
                        Text("No controller connected. Pair one in System Settings → Bluetooth, or plug it in.").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
            ForEach(Array(devices.connected.enumerated()), id: \.element.id) { i, c in
                ControllerCard(connected: c, profiles: profiles, header: i == 0 ? "Connected" : nil)
            }
            if !remembered.isEmpty {
                Section("Not connected") {
                    ForEach(remembered) { r in RememberedRow(remembered: r, profiles: profiles) }
                }
            }
            Section {
                DisclosureGroup("How a controller's profile is chosen", isExpanded: $showOrder) {
                    VStack(alignment: .leading, spacing: 6) {
                        orderStep(1, "A profile used everywhere")
                        orderStep(2, "In a game: the game's choice for this controller (its Controls tab → Per controller), then the game's profile")
                        orderStep(3, "In other apps: the app's rule, then the controller's own profile (with “Use a controller profile on the Mac” on), then the Mac's profile")
                        Text("On the Mac, every controller not set to another player drives player 1. Mac games get controllers set to player 2 and up as they are.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }.padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices.start(); devices.refresh(); devices.watch(true); profiles = PadProfiles.profiles() }
        .onDisappear { devices.watch(false) }
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in profiles = PadProfiles.profiles() }
    }

    func orderStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Circle().fill(Color.secondary.opacity(0.18)))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The picture for a controller: its own outline when Nokcandu knows its shape, otherwise a symbol for its kind.
struct ControllerArt: View {
    let family: Controllers.Family?
    let vendorID: Int
    let kind: Controllers.Kind
    var width: CGFloat
    var color: Color
    var buttons = false
    var lit: Set<PadProfiles.Input> = []

    /// Xbox, PlayStation, Nintendo and Steam controllers have outlines (Xbox's is also the one for no family).
    var outline: Controllers.Family?? {
        guard kind == .gamepad else { return nil }
        if let family { return .some(family) }
        if vendorID == 0x045E { return .some(nil) }
        return nil
    }
    var body: some View {
        if let f = outline { ControllerIcon(family: f, width: width, color: color, buttons: buttons, lit: lit) }
        else { Image(systemName: kind.symbol).font(.system(size: width * 0.55, weight: .regular)).foregroundStyle(color) }
    }
}

private struct ControllerCard: View {
    let connected: ControllerDevices.Connected
    let profiles: [PadProfiles.Profile]
    let header: String?
    @ObservedObject private var devices = ControllerDevices.shared
    @ObservedObject private var pad = DesktopPad.shared
    @State private var name = ""
    @State private var pingFailed = false
    @State private var pinged = false

    var remembered: ControllerRoster.Remembered? { devices.remembered(connected.key) }
    var held: [String] { devices.held[connected.key] ?? [] }
    var active: Bool { !held.isEmpty }
    var canPing: Bool { devices.canPing(connected.key) }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                    ControllerArt(family: connected.family, vendorID: connected.vendorID, kind: connected.kind, width: 70,
                                  color: active ? Color.accentColor.opacity(0.85) : .secondary, buttons: true, lit: devices.heldInputs[connected.key] ?? [])
                }
                .frame(width: 92, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(remembered?.name ?? connected.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Badge(text: remembered?.seat.title ?? "Auto", prominent: remembered?.seat.explicit != nil)
                    }
                    HStack(spacing: 10) {
                        if let b = connected.bluetooth {
                            Label(b ? "Bluetooth" : "USB", systemImage: b ? "dot.radiowaves.left.and.right" : "cable.connector.horizontal")
                        }
                        if remembered?.customName != nil { Text(connected.name) }
                        if connected.vendorID != 0 { Text(String(format: "%04X:%04X", connected.vendorID, connected.productID)).monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 8)
                Button {
                    pingFailed = !devices.ping(connected.key)
                    pinged = !pingFailed
                    if pinged { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pinged = false } }
                } label: {
                    Label(pinged ? "Buzzed" : "Ping", systemImage: pinged ? "checkmark" : "waveform.path").frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .disabled(!canPing)
                .help(canPing ? "A soft buzz on this controller" : devices.needsPress(connected.key) ? "Press a button on it first, to tell it apart from the other \(connected.name)" : "This controller can't buzz; press a button to see its card light up")
            }
            .padding(.vertical, 4)

            LabeledContent("Input") {
                HStack(spacing: 4) {
                    if held.isEmpty {
                        Text(devices.needsPress(connected.key) ? "Press a button to tell it apart from the other \(connected.name)" : "Press a button")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(held, id: \.self) { Keycap(text: $0) }
                    }
                }
                .frame(minHeight: 20)
            }
            let mac = devices.macStatus(connected.key, profiles: profiles)
            LabeledContent("On the Mac") { StatusText(main: mac.main, detail: mac.detail) }
            let win = devices.windowsStatus(connected.key)
            LabeledContent("Windows games") { StatusText(main: win.main, detail: win.detail) }

            TextField("Name", text: $name, prompt: Text(connected.name))
            Picker("Player", selection: Binding(get: { remembered?.seat ?? .auto }, set: { devices.setSeat(connected.key, $0) })) {
                Text("Auto").tag(ControllerRoster.Seat.auto)
                Divider()
                ForEach(1...8, id: \.self) { n in Text("Player \(n)").tag(ControllerRoster.Seat.player(n)) }
            }
            Picker(selection: Binding(get: { remembered?.fallbackProfileID ?? devices.ownProfile(connected) ?? "" },
                                      set: { devices.setFallback(connected.key, $0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                Divider()
                ForEach(profiles) { p in Text(p.name).tag(p.id) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Own profile")
                    Text("For apps and games with no profile of their own choosing").font(.caption).foregroundStyle(.secondary)
                }
            }
            if remembered?.byOrder == true && connected.vendorID != 0 && hasTwin {
                Label("No serial number Nokcandu can read: two of this model are told apart by the order they connected, and trade places if reconnected the other way round.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if pingFailed {
                Label("It didn't buzz. Press a button on it instead.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            if let header { Text(header) }
        }
        .animation(.easeOut(duration: 0.12), value: active)
        .onAppear { name = remembered?.customName ?? "" }
        .onChange(of: name) { _, n in if n != (remembered?.customName ?? "") { devices.rename(connected.key, n) } }
    }

    /// Another controller of the same model is remembered: only then can the order matter.
    var hasTwin: Bool {
        devices.roster.controllers.contains { $0.key != connected.key && $0.vendorID == connected.vendorID && $0.productID == connected.productID }
    }
}

private struct Badge: View {
    let text: String
    var prominent: Bool
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
            .foregroundStyle(prominent ? Color.accentColor : .secondary)
    }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(Color.accentColor)
    }
}

private struct StatusText: View {
    let main: String
    let detail: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(main)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
}

private struct RememberedRow: View {
    let remembered: ControllerRoster.Remembered
    let profiles: [PadProfiles.Profile]
    @ObservedObject private var devices = ControllerDevices.shared

    var body: some View {
        HStack(spacing: 12) {
            ControllerArt(family: Controllers.Family.of(vendorID: remembered.vendorID), vendorID: remembered.vendorID, kind: .gamepad, width: 30, color: .secondary)
                .frame(width: 36).opacity(0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(remembered.name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget") { devices.forget(remembered.key) }
                .buttonStyle(.borderless)
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
    func macStatus(_ key: String, profiles: [PadProfiles.Profile]) -> (main: String, detail: String?) {
        let pad = DesktopPad.shared
        guard pad.enabled else { return ("Controller profiles are off", nil) }
        if let n = roster.controller(key)?.seat.explicit, n > 1 { return ("Player \(n)", "Mac games get it as it is") }
        // Nothing used outside Nokcandu yet since it started: the Mac's settings.
        let ctx = pad.lastContext ?? DesktopPad.PadContext(game: nil, appName: nil, appRule: nil, everywhere: pad.everywhereID,
                                                           macDefault: pad.on ? pad.profileID : nil, macOn: pad.on, enabled: pad.enabled)
        let choice = ctx.game?.contents.flatMap { PadProfiles.controllerChoices(contents: $0)[key] }
        let own = connected.first { $0.key == key }.flatMap { ownProfile($0) }
        let r = ControllerRoster.resolve(everywhere: ctx.everywhere, game: ctx.game?.name, gameForController: choice, gameProfile: ctx.game?.profileID,
                                         appName: ctx.appName, appRule: ctx.appRule, controllerFallback: ctx.macOn ? own : nil, macDefault: ctx.macDefault)
        let place = ctx.game?.name ?? ctx.appName ?? "the Mac"
        let name = r.id.flatMap { id in profiles.first { $0.id == id }?.name }
        return ("Player 1 · " + (name ?? "no profile"), "In \(place): \(r.reason.words)")
    }
    /// The player a controller is in Windows games.
    func windowsStatus(_ key: String) -> (main: String, detail: String?) {
        guard connected.first(where: { $0.key == key })?.kind == .gamepad else { return ("As it is", "Not a gamepad") }
        let (n, reported) = windowsPlayer(key)
        let set = roster.controller(key)?.seat.explicit != nil
        return ("Player \(n)", reported ? "In the game running now" : set ? "Set here" : "Auto, by connection order")
    }
}
