// SPDX-License-Identifier: GPL-3.0-only
// The Streams tab: hosts and their stream profiles on the left, the chosen profile's setup and Stream button on the right.
import AppKit
import NokcanduCore
import SwiftUI

struct StreamsSidebar: View {
    @ObservedObject var m = StreamsModel.shared
    @State private var renaming: StreamHost?
    @State private var renameText = ""
    @State private var removing: StreamHost?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { m.selectedProfile.map { "p:" + $0 } ?? m.selectedHost.map { "h:" + $0 } },
                                    set: { sel in
                                        guard let sel else { return }
                                        if sel.hasPrefix("p:") { let id = String(sel.dropFirst(2)); m.selectedProfile = id; m.selectedHost = m.profile(id)?.hostID }
                                        else { m.selectedHost = String(sel.dropFirst(2)); m.selectedProfile = nil }
                                    })) {
                if m.library.hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No hosts yet").font(.headline)
                        Text("Stream games and the desktop from a PC running Sunshine. Connect to it below.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
                ForEach(m.library.hosts) { h in
                    Section {
                        ForEach(m.library.profiles(for: h.id)) { p in
                            profileRow(p, host: h).tag("p:" + p.id)
                                .contextMenu { profileMenu(p) }
                        }
                        if h.isPaired {
                            Button { m.addProfile(to: h.id) } label: { Label("Add Stream Profile", systemImage: "plus") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.callout)
                                .selectionDisabled()
                        }
                    } header: {
                        hostHeader(h).contextMenu { hostMenu(h) }
                    }
                }
                if !m.newlyDiscovered.isEmpty {
                    Section("On This Network") {
                        ForEach(m.newlyDiscovered) { d in
                            Button { m.showConnect = true; m.connect(to: d.address, name: d.name) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).lineLimit(1)
                                        Text("\(d.address) · Pair with this host").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain).selectionDisabled()
                        }
                    }
                }
            }
            Divider()
            Button { m.showConnect = true } label: { Label("Connect to Host…", systemImage: "plus.circle") }
                .buttonStyle(.borderless).labelStyle(AlignedIconLabelStyle())
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { m.startWatching() }
        .onDisappear { m.stopWatching() }
        .sheet(isPresented: $m.showConnect) { ConnectHostSheet() }
        .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let h = renaming { m.renameHost(h.id, renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove \(removing?.name ?? "host")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Host and Its Stream Profiles", role: .destructive) { if let h = removing { m.removeHost(h.id) }; removing = nil }
        } message: {
            Text("Its stream profiles are removed from this Mac, and the host is asked to forget this Mac. You can connect and pair again later.")
        }
    }

    private func hostHeader(_ h: StreamHost) -> some View {
        let s = m.status[h.id]
        return HStack(spacing: 6) {
            Circle().fill(s?.online == true ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(h.name)
            Spacer()
            if s?.checking == true { ProgressView().controlSize(.mini) }
            else if !h.isPaired || s?.needsPairing == true {
                Button("Pair…") { m.pairAgain(h) }.buttonStyle(.borderless).font(.caption).foregroundStyle(.orange)
            }
            else if s?.online != true { Text("Offline").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func profileRow(_ p: StreamProfile, host h: StreamHost) -> some View {
        let running = m.running?.profileID == p.id
        let app = p.appName ?? "No app chosen"
        return HStack(spacing: 10) {
            Image(systemName: p.route.isRemote ? "globe" : "play.tv").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if running { Circle().fill(.green).frame(width: 9, height: 9).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)).offset(x: 2, y: 2) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.headline).lineLimit(1)
                Text(running ? "Streaming" : app).font(.caption).foregroundStyle(running ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func hostMenu(_ h: StreamHost) -> some View {
        if h.isPaired { Button("Add Stream Profile") { m.addProfile(to: h.id) } }
        Button(h.isPaired ? "Pair Again…" : "Pair…") { m.pairAgain(h) }
        if h.macAddress != nil { Button("Wake Up") { m.wake(h) } }
        if (m.status[h.id]?.currentGame ?? 0) != 0 { Button("Quit App on Host") { m.quitApp(on: h) } }
        Button("Check Again") { m.refresh() }
        Divider()
        Button("Rename…") { renameText = h.name; renaming = h }
        Button("Remove Host…", role: .destructive) { removing = h }
    }

    @ViewBuilder private func profileMenu(_ p: StreamProfile) -> some View {
        Button("Stream") { m.stream(p) }.disabled(m.running != nil)
        Button("Duplicate") { m.addProfile(to: p.hostID, copying: p) }
        Divider()
        Button("Remove Stream Profile", role: .destructive) { m.removeProfile(p.id) }
    }
}

struct StreamsDetail: View {
    @ObservedObject var m = StreamsModel.shared

    var body: some View {
        Group {
            if let p = m.profile(m.selectedProfile), let h = m.host(p.hostID) {
                StreamProfileEditor(profile: p, host: h).id(p.id)
            } else if let h = m.host(m.selectedHost) {
                StreamHostSummary(host: h)
            } else {
                ContentUnavailableView {
                    Label("Streams", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Play games running on another computer. Install Sunshine on it, then connect to it here and pair with a PIN.")
                } actions: {
                    Button("Connect to Host…") { m.showConnect = true }.buttonStyle(.borderedProminent)
                    Link("Get Sunshine", destination: URL(string: "https://github.com/LizardByte/Sunshine")!)
                }
            }
        }
        .alert("Streams", isPresented: Binding(get: { m.lastError != nil }, set: { if !$0 { m.lastError = nil } })) {
            Button("OK") { m.lastError = nil }
        } message: { Text(m.lastError ?? "") }
    }
}

/// A host with no stream profile chosen.
struct StreamHostSummary: View {
    let host: StreamHost
    @ObservedObject var m = StreamsModel.shared

    var body: some View {
        let s = m.status[host.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name).font(.largeTitle.bold())
                        Text(s?.online == true ? (s?.currentGame ?? 0 != 0 ? "Online · running \(host.apps.first { $0.id == s?.currentGame }?.name ?? "an app")" : "Online") : (s?.error ?? "Offline"))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if host.isPaired { Button("Add Stream Profile") { m.addProfile(to: host.id) }.buttonStyle(.borderedProminent) }
                    else { Button("Pair…") { m.pairAgain(host) }.buttonStyle(.borderedProminent) }
                    if host.macAddress != nil, s?.online != true { Button("Wake Up") { m.wake(host) } }
                    if (s?.currentGame ?? 0) != 0 { Button("Quit App on Host", role: .destructive) { m.quitApp(on: host) } }
                }
                SettingsSection(title: "Addresses") {
                    LabeledContent("This network", value: host.localAddress ?? "—")
                    LabeledContent("Over the internet", value: host.remoteAddress ?? "—")
                    LabeledContent("Typed", value: host.manualAddress ?? "—")
                    LabeledContent("Host software", value: host.capabilities.isSunshine ? "Sunshine \(host.capabilities.appVersion)" : (host.capabilities.appVersion.isEmpty ? "—" : "GameStream \(host.capabilities.appVersion)"))
                }
            }
            .padding(28).frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)          // the scroll bar sits at the window's edge, the page stays centred
        }
    }
}

/// One stream profile: what the host starts and how the stream looks, sounds and takes input.
struct StreamProfileEditor: View {
    @State var profile: StreamProfile
    let host: StreamHost
    @ObservedObject var m = StreamsModel.shared
    @State private var padProfiles: [PadProfiles.Profile] = []
    @State private var customResolution = false

    private var running: Bool { m.running?.profileID == profile.id }
    private var status: StreamsModel.HostStatus? { m.status[host.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                appSection
                videoSection
                controllerSection
                inputSection
                audioSection
                microphoneSection
                connectionSection
            }
            .padding(28).frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)          // the scroll bar sits at the window's edge, the page stays centred
        }
        .onAppear {
            padProfiles = PadProfiles.profiles()
            customResolution = profile.video.width != nil
        }
        .onChange(of: profile) { _, p in m.setProfile(p) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            artwork.frame(width: 96, height: 128).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $profile.name).font(.largeTitle.bold()).textFieldStyle(.plain)
                Text("\(host.name) · \(profile.appName ?? "No app chosen")").foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        if running { m.showStream() } else { m.stream(profile) }
                    } label: { Label(running ? "Streaming" : "Stream", systemImage: "play.fill").frame(minWidth: 90) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!host.isPaired || profile.appID == nil || (m.running != nil && !running))
                    if running {
                        Button("End Stream") { m.endStream(quitApp: false) }.controlSize(.large)
                        Button("End and Quit App…", role: .destructive) { m.endStream(quitApp: true) }.controlSize(.large)
                    } else if (status?.currentGame ?? 0) != 0 {
                        Button("Quit App on Host", role: .destructive) { m.quitApp(on: host) }.controlSize(.large)
                    }
                    if status?.online != true, host.macAddress != nil { Button("Wake Up") { m.wake(host) }.controlSize(.large) }
                    if !host.isPaired || status?.needsPairing == true { Button("Pair…") { m.pairAgain(host) }.controlSize(.large) }
                }
                if running {
                    SettingNote("Streaming now. Changes apply straight away, except the picture's resolution, frame rate, bitrate, codec, HDR and colour settings, sound channels, \"Also play on the host\", the app and the connection, which the host sets when a stream starts: those apply from the next stream.")
                }
                if !host.isPaired { SettingNote("Pair with \(host.name) to stream.", warning: true) }
                else if status?.needsPairing == true { SettingNote("\(host.name) no longer accepts this Mac (its pairings may have been reset). Pair again.", warning: true) }
                else if status?.online == false { SettingNote("\(host.name) isn't answering. \(status?.error ?? "")", warning: true) }
                else if status?.busy == true, (status?.currentGame ?? 0) != profile.appID { SettingNote("\(host.name) is already streaming to another device.") }
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        if let id = profile.appID, let img = m.artwork(host: host, app: id), img.isValid, img.size.width > 0 {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15))
                Image(systemName: profile.appName?.localizedCaseInsensitiveContains("desktop") == true ? "menubar.dock.rectangle" : "gamecontroller")
                    .font(.system(size: 34)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var summary: String {
        let v = profile.video
        let res = v.width.map { "\($0)×\(v.height ?? 0)" } ?? "This Mac's display"
        let rate = v.bitrateKbps.map { "\($0 / 1000) Mbit/s" } ?? "automatic bitrate"
        return "\(res) · \(v.fps) fps · \(v.codec.title) · \(rate)"
    }

    // MARK: Sections

    private var appSection: some View {
        SettingsSection(title: "App", info: "What the host starts. Hosts list their desktop, Steam Big Picture, virtual displays and any games or apps added in Sunshine's Applications page.") {
            SettingRow(title: "Starts") {
                Picker("Starts", selection: Binding(get: { profile.appID ?? -1 }, set: { id in
                    profile.appID = id < 0 ? nil : id
                    profile.appName = host.apps.first { $0.id == id }?.name ?? profile.appName
                })) {
                    if profile.appID == nil { Text("Choose…").tag(-1) }
                    if let id = profile.appID, !host.apps.contains(where: { $0.id == id }) { Text(profile.appName ?? "App \(id)").tag(id) }
                    ForEach(host.apps) { a in Text(a.name).tag(a.id) }
                }
                .labelsHidden().frame(maxWidth: 280)
            }
            if host.apps.isEmpty { SettingNote(host.isPaired ? "The app list appears when \(host.name) is online." : "Pair first to see the host's apps.") }
            SettingToggle(title: "Optimize game settings", info: "Lets the host change a game's resolution and quality to suit this stream (GameStream's \"optimize game settings\").",
                          isOn: $profile.optimizeGameSettings)
        }
    }

    private static let resolutions: [(String, Int, Int)] = [("720p", 1280, 720), ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K", 3840, 2160),
                                                            ("1080p ultrawide", 2560, 1080), ("1440p ultrawide", 3440, 1440), ("16:10 1200p", 1920, 1200), ("16:10 1600p", 2560, 1600)]

    private var videoSection: some View {
        SettingsSection(title: "Picture") {
            SettingRow(title: "Resolution", info: "\"This Mac's display\" asks the host for exactly the pixels of the display the stream plays on (see Display). Sunshine with a virtual display matches it; otherwise the host scales.") {
                Picker("Resolution", selection: Binding(get: { profile.video.width.map { "\($0)x\(profile.video.height ?? 0)" } ?? "display" }, set: { v in
                    if v == "display" { profile.video.width = nil; profile.video.height = nil; customResolution = false }
                    else if v == "custom" { customResolution = true; if profile.video.width == nil { profile.video.width = 1920; profile.video.height = 1080 } }
                    else { let p = v.split(separator: "x").compactMap { Int($0) }; profile.video.width = p.first; profile.video.height = p.last; customResolution = false }
                })) {
                    Text("This Mac's display").tag("display")
                    ForEach(Self.resolutions, id: \.0) { r in Text("\(r.0) (\(r.1)×\(r.2))").tag("\(r.1)x\(r.2)") }
                    if let w = profile.video.width, let h = profile.video.height, !Self.resolutions.contains(where: { $0.1 == w && $0.2 == h }) { Text("\(w)×\(h)").tag("\(w)x\(h)") }
                    Divider()
                    Text("Custom…").tag("custom")
                }
                .labelsHidden().frame(maxWidth: 240)
            }
            if customResolution {
                SettingRow(title: "Size in pixels") {
                    TextField("Width", value: Binding(get: { profile.video.width ?? 1920 }, set: { profile.video.width = max(320, min(7680, $0 / 2 * 2)) }), format: .number.grouping(.never)).frame(width: 70)
                    Text("×")
                    TextField("Height", value: Binding(get: { profile.video.height ?? 1080 }, set: { profile.video.height = max(200, min(4320, $0 / 2 * 2)) }), format: .number.grouping(.never)).frame(width: 70)
                }
            }
            SettingRow(title: "Frame rate") {
                Picker("Frame rate", selection: $profile.video.fps) {
                    ForEach([30, 60, 90, 120, 144, 165, 240], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .labelsHidden().frame(maxWidth: 140)
            }
            SettingRow(title: "Bitrate", info: "How much data the host sends. More is sharper but needs a faster network; streaming over the internet usually needs less (10–30 Mbit/s).") {
                let auto = StreamProfile.Video.defaultBitrate(width: profile.video.width ?? 2940, height: profile.video.height ?? 1838, fps: profile.video.fps, yuv444: profile.video.yuv444)
                let kbps = profile.video.bitrateKbps ?? auto
                Toggle("Automatic", isOn: Binding(get: { profile.video.bitrateKbps == nil }, set: { profile.video.bitrateKbps = $0 ? nil : auto }))
                // Moving the slider sets your own bitrate; Automatic follows the resolution and frame rate.
                Slider(value: Binding(get: { Double(kbps) / 1000 }, set: { profile.video.bitrateKbps = Int($0) * 1000 }), in: 1...150, step: 1).frame(width: 160)
                Text("\(kbps / 1000) Mbit/s").monospacedDigit().frame(width: 76, alignment: .trailing)
                    .foregroundStyle(profile.video.bitrateKbps == nil ? .secondary : .primary)
            }
            SettingRow(title: "Codec", info: "HEVC and AV1 look better than H.264 at the same bitrate. AV1 needs a Mac with an M3 or later chip and a host GPU that encodes it.") {
                Picker("Codec", selection: $profile.video.codec) { ForEach(StreamProfile.Video.Codec.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 200)
            }
            SettingToggle(title: "HDR", info: "When the host's display and the game use HDR, the stream is sent in 10-bit HDR (HEVC or AV1) and shown in HDR on Mac displays that support it.",
                          isOn: $profile.video.hdr)
            SettingToggle(title: "Full colour (4:4:4)", info: "Sharper coloured text and edges, for desktop use. Needs a host GPU that encodes 4:4:4, and about twice the bitrate.",
                          isOn: $profile.video.yuv444)
            SettingRow(title: "Frame pacing", info: "Lowest latency shows each frame the moment it's decoded. Balanced waits for the display's next refresh. Smoothest holds a frame in reserve to hide network hiccups, adding about one frame of delay.") {
                Picker("Frame pacing", selection: $profile.video.pacing) { ForEach(StreamProfile.Video.Pacing.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 180)
            }
            SettingRow(title: "Frames to buffer", info: "Decoded frames held before they're shown. 0 shows each frame the moment it arrives (lowest delay); more frames smooth out an uneven network or Wi-Fi at about one display refresh of delay each. Automatic follows Frame pacing (0, 1 or 2).") {
                let buffered = profile.video.frameBuffer ?? StreamVideoDecoder.defaultBuffer(profile.video.pacing)
                Toggle("Automatic", isOn: Binding(get: { profile.video.frameBuffer == nil }, set: { profile.video.frameBuffer = $0 ? nil : buffered }))
                Stepper(value: Binding(get: { buffered }, set: { profile.video.frameBuffer = $0 }), in: 0...4) {
                    Text("\(buffered)").monospacedDigit().frame(width: 20, alignment: .trailing)
                        .foregroundStyle(profile.video.frameBuffer == nil ? .secondary : .primary)
                }
            }
            SettingToggle(title: "Full-range colour", info: "Ask for 0–255 colour instead of 16–235. Turn on if blacks look grey or the picture looks washed out.",
                          isOn: $profile.video.fullRange)
            StreamDisplayRow(window: $profile.window)
            SettingRow(title: "Full screen", info: "In full screen, macOS turns on Game Mode for the stream: the Mac puts the stream first and halves Bluetooth latency for controllers and AirPods. You can turn it off from the Game Mode icon in the menu bar while streaming.") {
                Toggle("Full screen", isOn: $profile.window.fullScreen).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(title: "Statistics", info: "Shown over the picture. ⌃⌥⇧S cycles through them during a stream.") {
                Picker("Statistics", selection: $profile.window.statistics) { ForEach(StreamProfile.Window.Statistics.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 200)
            }
        }
    }

    private var controllerSection: some View {
        SettingsSection(title: "Controller", info: "With a Nokcandu controller profile, the stream gets exactly what the profile makes of your controller: its remapped buttons, sticks, gyro aiming, trackpads, keys and mouse, layers and radial menus. Without one, controllers go to the host as they are.") {
            SettingRow(title: "Controller profile") {
                Picker("Controller profile", selection: $profile.controller.profileID) {
                    Text("Controller as it is").tag(String?.none)
                    if !padProfiles.isEmpty { Divider() }
                    ForEach(padProfiles) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            SettingRow(title: "Emulated controller type", info: "The kind of controller the host's games see. Automatic sends each controller as its own kind (PlayStation pads as PlayStation, Switch pads as Switch, others as Xbox), or as the Nokcandu profile's Emulated controller when it has one. PlayStation adds the touchpad and motion; Switch uses Nintendo's button layout. \"No controller\" sends none at all: with a Nokcandu profile, only what it turns into keys, clicks, mouse movement and scrolling reaches the host, so games see a keyboard and mouse.") {
                Picker("Emulated controller type", selection: $profile.controller.sendAs) {
                    ForEach(StreamProfile.Controller.SendAs.allCases.filter { $0 != .profileOnly }, id: \.self) { Text($0.title).tag($0) }
                    Divider()
                    Text(StreamProfile.Controller.SendAs.profileOnly.title).tag(StreamProfile.Controller.SendAs.profileOnly)
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            if profile.controller.sendAs == .profileOnly {
                SettingNote(profile.controller.profileID == nil
                            ? "No controller is sent. Choose a Nokcandu controller profile above to use your controller as keys and mouse."
                            : "No controller is sent: the profile's keys, mouse and scrolling go to the host.")
            }
            if profile.controller.profileID == nil, profile.controller.sendAs != .profileOnly {
                SettingToggle(title: "Each controller is its own player", isOn: $profile.controller.multipleControllers)
            }
            SettingToggle(title: "Swap A/B and X/Y", info: "For Nintendo-style layouts, where the confirm button is on the right.", isOn: $profile.controller.swapFaceButtons)
            if profile.controller.profileID == nil {
                SettingToggle(title: "Send motion", info: "Passes the controller's gyro and accelerometer to games that ask for them (sent as a PlayStation or Switch controller). With a Nokcandu profile, its own gyro settings apply instead.", isOn: $profile.controller.motion)
            }
        }
    }

    private var inputSection: some View {
        SettingsSection(title: "Keyboard and Mouse") {
            SettingRow(title: "Mouse", info: "Captured locks the pointer to the stream and sends movement, as games expect; ⌃⌥⇧Z frees it. Pointer moves the host's pointer to where yours is, for desktop use.") {
                Picker("Mouse", selection: $profile.input.mouse) { ForEach(StreamProfile.Input.Mouse.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 220)
            }
            SettingRow(title: "Keyboard layout", info: "The keyboard layout (from Controls → Keyboard Layouts) used while the stream is in front, with macOS's own key remapping, so every key works, Caps Lock and modifiers included. The default layout is the one your games follow. The keyboard goes back when you switch away or the stream ends.") {
                Picker("Keyboard layout", selection: $profile.input.keyboardLayout) {
                    let layouts = KeyRemap.layouts()
                    Text(KeyRemap.defaultLayout(layouts: layouts).map { "The default layout (\($0.name))" } ?? "The default layout (none set)").tag(String?.none)
                    Text("Normal keys").tag(Optional("none"))
                    if !layouts.isEmpty { Divider() }
                    ForEach(layouts) { l in Text(l.name).tag(Optional(l.id)) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            SettingToggle(title: "Reverse scrolling", isOn: $profile.input.reverseScroll)
            SettingToggle(title: "⌘ is the Windows key", info: "⌘ shortcuts go to the host as Windows-key shortcuts while the stream is in front. Off, ⌘ stays with the Mac (⌘Q quits Nokcandu).", isOn: $profile.input.commandAsWindowsKey)
            SettingToggle(title: "Share the clipboard", info: "With an Apollo host: copied text on the Mac goes to the host when the stream comes to the front, and text copied on the host comes back when you switch away. In Apollo, allow this Mac's clipboard permissions under Device Management. The Stream menu can also send or fetch it by hand. While this is on, anything you copy on the Mac, passwords included, is sent to the host when you return to the stream.", isOn: $profile.input.clipboard)
            SettingToggle(title: "Swap ⌥ and ⌘", info: "For a Windows keyboard layout: ⌥ is the Windows key and ⌘ is Alt.", isOn: $profile.input.swapOptionCommand)
            SettingNote("During a stream: ⌃⌥⇧Q ends it, ⌃⌥⇧Z frees or captures the pointer, ⌃⌥⇧X switches full screen, ⌃⌥⇧S shows statistics.")
        }
    }

    private var audioSection: some View {
        SettingsSection(title: "Sound") {
            SettingRow(title: "Channels") {
                Picker("Channels", selection: $profile.audio.channels) { ForEach(StreamProfile.Audio.Channels.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 160)
            }
            SettingRow(title: "Play on", info: "The Mac's output for the stream's sound. The Mac's default follows whatever macOS uses, including when you switch it in Control Center. A chosen output that isn't connected falls back to the default.") {
                Picker("Play on", selection: $profile.audio.outputDevice) {
                    Text("The Mac's default output").tag(String?.none)
                    let devices = StreamAudioPlayer.outputDevices()
                    if !devices.isEmpty { Divider() }
                    ForEach(devices, id: \.uid) { d in Text(d.name).tag(Optional(d.uid)) }
                    if let uid = profile.audio.outputDevice, !devices.contains(where: { $0.uid == uid }) { Text("Not connected").tag(Optional(uid)) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            SettingRow(title: "Volume") {
                Slider(value: $profile.audio.volume, in: 0...1).frame(width: 180)
            }
            SettingToggle(title: "Also play on the host", isOn: $profile.audio.playOnHost)
        }
    }

    /// The microphone sent over VBAN: separate from the stream's own sound, which comes from the host.
    private var microphoneSection: some View {
        SettingsSection(title: "Microphone (VBAN)", info: "Sends this Mac's microphone to the PC over VBAN while you stream, like VBAN Talkie. This is separate from the stream's sound above, which comes from the PC. On the PC, receive it with VBAN Receptor or Voicemeeter: an incoming stream with the same stream name, from this Mac's address, on port 6980. VBAN is not encrypted: anyone on the same network could listen, so use it on a network you trust.") {
            SettingToggle(title: "Send the microphone", isOn: $profile.audio.vban.enabled)
            if profile.audio.vban.enabled {
                SettingRow(title: "Microphone") {
                    Picker("Microphone", selection: $profile.audio.vban.inputDevice) {
                        Text("The Mac's default input").tag(String?.none)
                        ForEach(StreamVBANSender.microphones(), id: \.id) { m in Text(m.name).tag(Optional(m.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                }
                SettingRow(title: "Send to", info: "Empty sends to the stream's host. Type another computer's address to send there instead.") {
                    TextField(host.localAddress ?? "the host", text: Binding(get: { profile.audio.vban.address ?? "" },
                                                                              set: { profile.audio.vban.address = $0.isEmpty ? nil : $0 }))
                        .frame(width: 160)
                    Text("Port")
                    TextField("6980", value: $profile.audio.vban.port, format: .number.grouping(.never)).frame(width: 60)
                }
                SettingRow(title: "Stream name", info: "VBAN Receptor and Voicemeeter accept an incoming stream by this name (up to 16 characters).") {
                    TextField("Stream1", text: Binding(get: { profile.audio.vban.streamName }, set: { profile.audio.vban.streamName = String($0.prefix(16)) }))
                        .frame(width: 160)
                }
                SettingRow(title: "Format") {
                    Picker("Channels", selection: $profile.audio.vban.channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
                        .labelsHidden().frame(width: 100)
                    Picker("Sample rate", selection: $profile.audio.vban.sampleRate) {
                        ForEach([48000, 44100, 32000, 24000, 16000], id: \.self) { Text("\($0 / 1000 == 44 ? "44.1" : "\($0 / 1000)") kHz").tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                SettingRow(title: "Network", info: "Audio in each packet. Lowest latency sends small packets often; Steady sends larger ones, which copes better with a busy Wi-Fi network (like VBAN Talkie's network quality).") {
                    Picker("Network", selection: $profile.audio.vban.packetSamples) {
                        Text("Lowest latency").tag(64); Text("Fast").tag(128); Text("Steady").tag(256)
                    }
                    .labelsHidden().frame(width: 160)
                }
                if running { VBANMeter() }
                vbanKnob("Gain", value: $profile.audio.vban.gainDB, range: -12...24, unit: "dB", info: "Makes the microphone louder or quieter before it's sent.")
                vbanKnob("Noise gate", value: $profile.audio.vban.gate, range: 0...1, unit: "", info: "Silences the microphone when you aren't speaking, so keyboard and room noise don't come through. Higher shuts out louder sounds; off at 0.")
                vbanKnob("Compressor", value: $profile.audio.vban.compressor, range: 0...1, unit: "", info: "Evens out loud and quiet speech so you're heard at a steady level. Off at 0.")
                vbanKnob("Bass", value: $profile.audio.vban.bassDB, range: -12...12, unit: "dB", info: "Below about 150 Hz.")
                vbanKnob("Mid", value: $profile.audio.vban.midDB, range: -12...12, unit: "dB", info: "Around 1.5 kHz, where speech is clearest.")
                vbanKnob("Treble", value: $profile.audio.vban.trebleDB, range: -12...12, unit: "dB", info: "Above about 5 kHz.")
                SettingToggle(title: "Push to talk", info: "Sends your voice only while you hold the key or mouse button below, whichever app is in front. The key isn't passed to the host. Mute with ⌃⌥⇧M or the Stream menu.",
                              isOn: $profile.audio.vban.pushToTalk)
                if profile.audio.vban.pushToTalk {
                    SettingRow(title: "Talk while holding") {
                        Picker("Talk while holding", selection: Binding(get: { profile.audio.vban.pushToTalkInput ?? "" }, set: { profile.audio.vban.pushToTalkInput = $0.isEmpty ? nil : $0 })) {
                            Text("Choose…").tag("")
                            ForEach(Self.pushToTalkInputs, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    if profile.audio.vban.pushToTalkInput == nil { SettingNote("Choose a key or button: until then nothing is sent.", warning: true) }
                }
            }
        }
    }

    private var connectionSection: some View {
        SettingsSection(title: "Connection", info: "Make one stream profile for home and another for away, each with its own address and quality.") {
            SettingRow(title: "Connect through") {
                Picker("Connect through", selection: Binding(get: { routeTag }, set: { tag in
                    switch tag {
                    case "local": profile.route = .local
                    case "remote": profile.route = .remote
                    case "manual": profile.route = .manual(host.manualAddress ?? host.localAddress ?? "")
                    default: profile.route = .automatic
                    }
                })) {
                    Text("Automatic").tag("auto")
                    Text("This network\(host.localAddress.map { " (\($0))" } ?? "")").tag("local")
                    Text("Over the internet\(host.remoteAddress.map { " (\($0))" } ?? "")").tag("remote")
                    Text("This address…").tag("manual")
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            if case .manual(let a) = profile.route {
                SettingRow(title: "Address") {
                    TextField("name, IP or IP:port", text: Binding(get: { a }, set: { profile.route = .manual($0) })).frame(width: 220)
                }
            }
            if profile.route.isRemote { SettingNote("Over the internet, the host's router needs ports 47984–48010 forwarded to it, or use a VPN such as Tailscale and choose its address.") }
        }
    }

    /// Keys and buttons that make good push-to-talk inputs (rarely used by games, or easy to reach).
    static let pushToTalkInputs: [(String, String)] = [
        ("Mouse side button (back)", "mouse:3"), ("Mouse side button (forward)", "mouse:4"), ("Middle mouse button", "mouse:2"),
        ("` (backquote)", "key:50"), ("Caps Lock", "key:57"), ("Right ⌥ Option", "key:61"), ("Right ⌘ Command", "key:54"),
        ("Right ⇧ Shift", "key:60"), ("fn", "key:63"), ("F13", "key:105"), ("F14", "key:107"), ("F15", "key:113"),
        ("V", "key:9"), ("T", "key:17"),
    ]

    private func vbanKnob(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, info: String) -> some View {
        SettingRow(title: title, info: info) {
            Slider(value: value, in: range).frame(width: 180)
            Text(unit == "dB" ? String(format: "%+.0f dB", value.wrappedValue) : (value.wrappedValue == 0 ? "Off" : String(format: "%.0f%%", value.wrappedValue * 100)))
                .monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    private var routeTag: String {
        switch profile.route { case .automatic: "auto"; case .local: "local"; case .remote: "remote"; case .manual: "manual" }
    }
}

/// Connect to Host: hosts found on this network, or an address typed in; then the PIN to type on the host.
struct ConnectHostSheet: View {
    @ObservedObject var m = StreamsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = m.pairing { pairingView(p) } else { chooser }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Host").font(.title2.bold())
            Text("Hosts run Sunshine (or NVIDIA GameStream). Found on this network:").foregroundStyle(.secondary)
            if m.discovered.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 6) {
                    ForEach(m.discovered) { d in
                        Button { m.connect(to: d.address, name: d.name) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) { Text(d.name); Text(d.address).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if m.library.hosts.contains(where: { $0.localAddress == d.address && $0.isPaired }) { Text("Paired").font(.caption).foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Divider()
            Text("Or type its address").font(.headline)
            HStack {
                TextField("Name or IP address, e.g. 192.168.1.20", text: $address).textFieldStyle(.roundedBorder).onSubmit(connectTyped)
                Button("Connect", action: connectTyped).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Works with IPv6, a port (host:47989), or a VPN address such as Tailscale's.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .onAppear { m.startDiscovery() }
    }

    private func connectTyped() {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        m.update { lib in
            if !lib.hosts.contains(where: { $0.manualAddress == a || $0.localAddress == a }) {
                var h = StreamHost(id: "manual:" + a, name: a); h.manualAddress = a
                lib.hosts.append(h)
            }
        }
        m.connect(to: a)
    }

    @ViewBuilder private func pairingView(_ p: StreamsModel.Pairing) -> some View {
        Text("Pair with \(p.name)").font(.title2.bold())
        switch p.stage {
        case .waiting:
            Text("On the host, open Sunshine's web page (https://localhost:47990 on the host), go to **PIN**, and enter:")
            Text(p.pin).font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit().tracking(10)
                .frame(maxWidth: .infinity).padding(.vertical, 6).textSelection(.enabled)
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for the PIN on the host…").foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { m.cancelPairing() }.keyboardShortcut(.cancelAction) }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Back") { m.cancelPairing() }
                Button("Try Again") { m.connect(to: p.address, name: p.name) }.keyboardShortcut(.defaultAction)
            }
        case .done:
            Label("Paired. Your first stream profile is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            HStack { Spacer(); Button("Done") { m.pairing = nil; dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }
}

/// The Stream menu in the menu bar: always there to end a stream, whatever has the keyboard.
struct StreamCommands: View {
    @ObservedObject var m = StreamsModel.shared
    var body: some View {
        Button("Show Stream") { m.showStream() }.disabled(m.running == nil)
        Button("Free or Capture the Pointer") { m.togglePointer() }.disabled(m.running == nil)
            .keyboardShortcut("z", modifiers: [.control, .option, .shift])
        Button("Mute or Unmute the Microphone (VBAN)") { m.toggleMicMute() }.disabled(m.running == nil)
            .keyboardShortcut("m", modifiers: [.control, .option, .shift])
        Button("Send Clipboard to Host") { m.sendClipboard() }.disabled(m.running == nil)
        Button("Copy the Host's Clipboard") { m.fetchClipboard() }.disabled(m.running == nil)
        Divider()
        Button("End Stream") { m.endStream(quitApp: false) }.disabled(m.running == nil)
            .keyboardShortcut("q", modifiers: [.control, .option, .shift])
        Button("End Stream and Quit the App on the Host") { m.endStream(quitApp: true) }.disabled(m.running == nil)
    }
}

/// The running stream in Nokcandu's menu bar menu.
struct StreamMenuBarSection: View {
    @ObservedObject var m = StreamsModel.shared
    var body: some View {
        if m.running != nil {
            Section("Streaming \(m.streamName ?? "")") {
                Button("Show Stream") { m.showStream() }
                Button("End Stream") { m.endStream(quitApp: false) }
                Button("End Stream and Quit the App on the Host") { m.endStream(quitApp: true) }
            }
        }
    }
}

/// The VBAN microphone's level during a stream.
struct VBANMeter: View {
    @ObservedObject var m = StreamsModel.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let level = m.micLevel
            SettingRow(title: "Microphone level") {
                if let level {
                    let db = level > 0 ? 20 * log10(Double(level)) : -60
                    let fill = max(0, min(1, (db + 48) / 48))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(db > -3 ? Color.red : db > -12 ? Color.yellow : Color.green).frame(width: 180 * fill)
                    }
                    .frame(width: 180, height: 8)
                    Text(level > 0 ? String(format: "%.0f dB", db) : "silent").monospacedDigit().frame(width: 56, alignment: .trailing).font(.caption)
                } else {
                    Text("Not sending").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }
}


/// Window → Display: which of the Mac's displays the stream plays on.
struct StreamDisplayRow: View {
    @Binding var window: StreamProfile.Window
    @State private var screens: [(id: String, label: String)] = []

    var body: some View {
        SettingRow(title: "Display", info: "The display the stream opens on, and full screen on. \"The display Nokcandu is on\" follows Nokcandu's window. A chosen display that isn't connected falls back to that. Changing it mid-stream moves the stream; the picture size stays as it started until the next stream.\n\nAn HDMI dummy plug or a virtual display counts as a display: if streams open where you can't see them, choose the screen you're using here.") {
            Picker("Display", selection: Binding(get: { window.display }, set: { id in
                window.display = id
                window.displayName = id.flatMap { i in screens.first { $0.id == i }?.label } ?? nil
            })) {
                Text("The display Nokcandu is on").tag(String?.none)
                if !screens.isEmpty { Divider() }
                ForEach(screens, id: \.id) { Text($0.label).tag(Optional($0.id)) }
                if let id = window.display, !screens.contains(where: { $0.id == id }) {
                    Text("\(window.displayName ?? "A display") — not connected").tag(Optional(id))
                }
            }
            .labelsHidden().frame(maxWidth: 260)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in refresh() }
    }

    private func refresh() {
        screens = NSScreen.screens.compactMap { s in StreamDisplays.id(s).map { ($0, StreamDisplays.label(s)) } }
    }
}
