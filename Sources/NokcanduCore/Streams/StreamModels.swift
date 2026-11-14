// SPDX-License-Identifier: GPL-3.0-only
// Streams: game streaming from a PC running Sunshine (or another GameStream host) to this Mac.
// The protocol side follows Moonlight and VoidLink; see docs/streams.md.
import Foundation

/// A computer that streams to this Mac.
public struct StreamHost: Codable, Hashable, Identifiable, Sendable {
    /// The host's own unique ID (serverinfo `uniqueid`), or a placeholder until it first answers.
    public var id: String
    public var name: String
    /// The address it was last reached at on this network.
    public var localAddress: String?
    /// Its address from outside its own network (serverinfo `ExternalIP`), for streaming away from home.
    public var remoteAddress: String?
    /// An address typed by hand (a name, IPv4 or IPv6, optionally with :port), tried first.
    public var manualAddress: String?
    public var httpPort: UInt16 = 47989
    public var httpsPort: UInt16 = 47984
    /// The host's certificate from pairing, DER, base64. Set means paired.
    public var serverCertificate: String?
    /// For Wake-on-LAN.
    public var macAddress: String?
    /// The apps the host offered last time.
    public var apps: [StreamApp] = []
    /// What the host told us it can do, from its last answer.
    public var capabilities = Capabilities()

    public struct Capabilities: Codable, Hashable, Sendable {
        public var appVersion = ""
        public var gfeVersion = ""
        /// ServerCodecModeSupport bits (H.264, HEVC, HEVC Main10, AV1 Main8/Main10, YUV 4:4:4).
        public var codecModes: Int = 0
        public var maxLumaPixelsHEVC: Int = 0
        public var isSunshine: Bool { appVersion.split(separator: ".").last?.hasPrefix("-") ?? false }
        public init() {}
    }

    public init(id: String, name: String) { self.id = id; self.name = name }

    public var isPaired: Bool { serverCertificate != nil }

    /// Addresses to try, best first, without repeats.
    public func candidates(_ preference: StreamProfile.Route = .automatic) -> [String] {
        var list: [String?]
        switch preference {
        case .automatic: list = [manualAddress, localAddress, remoteAddress]
        case .local: list = [localAddress, manualAddress]
        case .remote: list = [remoteAddress, manualAddress]
        case .manual(let a): list = [a]
        }
        var seen = Set<String>()
        return list.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // Older saved hosts won't have every field.
    private enum CodingKeys: String, CodingKey {
        case id, name, localAddress, remoteAddress, manualAddress, httpPort, httpsPort, serverCertificate, macAddress, apps, capabilities
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        localAddress = try c.decodeIfPresent(String.self, forKey: .localAddress)
        remoteAddress = try c.decodeIfPresent(String.self, forKey: .remoteAddress)
        manualAddress = try c.decodeIfPresent(String.self, forKey: .manualAddress)
        httpPort = try c.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 47989
        httpsPort = try c.decodeIfPresent(UInt16.self, forKey: .httpsPort) ?? 47984
        serverCertificate = try c.decodeIfPresent(String.self, forKey: .serverCertificate)
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        apps = try c.decodeIfPresent([StreamApp].self, forKey: .apps) ?? []
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? Capabilities()
    }
}

/// Something the host can start: its desktop, Steam Big Picture, a virtual display, a game…
public struct StreamApp: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var supportsHDR: Bool = false
    public init(id: Int, name: String, supportsHDR: Bool = false) { self.id = id; self.name = name; self.supportsHDR = supportsHDR }
}

/// How one stream from one host is set up. A host can have several ("Home", "Away", "4K TV").
public struct StreamProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var hostID: String
    public var name: String
    /// The app the host starts (by ID, with its name kept for when the host is offline).
    public var appID: Int?
    public var appName: String?
    public var route: Route = .automatic
    public var video = Video()
    public var audio = Audio()
    public var controller = Controller()
    public var input = Input()
    public var window = Window()
    /// Ask the host to change the game's settings for this stream's resolution (GameStream "SOPS").
    public var optimizeGameSettings = true

    public init(id: String = UUID().uuidString, hostID: String, name: String) { self.id = id; self.hostID = hostID; self.name = name }

    /// Which of the host's addresses to use.
    public enum Route: Codable, Hashable, Sendable {
        case automatic, local, remote
        case manual(String)
        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .local: "This network"
            case .remote: "Over the internet"
            case .manual(let a): a
            }
        }
        public var isRemote: Bool { if case .remote = self { return true }; return false }
    }

    public struct Video: Codable, Hashable, Sendable {
        /// nil: this Mac's display (the window's screen, in pixels).
        public var width: Int?
        public var height: Int?
        public var fps: Int = 60
        /// Kbit/s; nil picks one from the resolution and frame rate.
        public var bitrateKbps: Int?
        public var codec: Codec = .automatic
        public var hdr = false
        public var yuv444 = false
        public var pacing: Pacing = .balanced
        /// Decoded frames held before showing (0…4); nil follows the pacing (0, 1 or 2).
        public var frameBuffer: Int?
        /// Full-range colour (0–255) instead of limited (16–235).
        public var fullRange = false
        /// Apple's low-latency frame interpolation doubles the frames shown (macOS 26 and later, Apple silicon).
        public var interpolation = false
        /// Apple's low-latency super resolution upscales a lower-resolution stream to the window (macOS 26 and later).
        public var upscaling = false
        public init() {}

        public enum Codec: String, Codable, CaseIterable, Sendable {
            case automatic, h264, hevc, av1
            public var title: String {
                switch self { case .automatic: "Automatic"; case .h264: "H.264"; case .hevc: "HEVC (H.265)"; case .av1: "AV1" }
            }
        }
        public enum Pacing: String, Codable, CaseIterable, Sendable {
            /// Show each frame the moment it's decoded.
            case lowestLatency
            /// Show frames on the display's next refresh.
            case balanced
            /// Hold one frame back to even out network jitter.
            case smoothest
            public var title: String {
                switch self { case .lowestLatency: "Lowest latency"; case .balanced: "Balanced"; case .smoothest: "Smoothest" }
            }
        }

        /// Moonlight's default bitrate for a resolution and frame rate, in Kbit/s: interpolated between
        /// 360p (1 Mbit/s at 30 fps) and 4K (40 Mbit/s), rising more slowly above 60 fps.
        public static func defaultBitrate(width: Int, height: Int, fps: Int, yuv444: Bool = false) -> Int {
            let table: [(pixels: Double, factor: Double)] = [(640 * 360, 1), (854 * 480, 2), (1280 * 720, 5), (1920 * 1080, 10), (2560 * 1440, 20), (3840 * 2160, 40)]
            let px = Double(max(1, width * height))
            var res = table.last!.factor
            for (i, row) in table.enumerated() where px <= row.pixels {
                if i == 0 { res = row.factor } else {
                    let lo = table[i - 1]
                    res = lo.factor + (px - lo.pixels) / (row.pixels - lo.pixels) * (row.factor - lo.factor)
                }
                break
            }
            if yuv444 { res *= 2 }
            let f = Double(max(1, fps))
            let rate = f <= 60 ? f / 30 : (60 + (f - 60) / 2) / 30
            return min(150_000, Int((res * rate).rounded()) * 1000)
        }
    }

    public struct Audio: Codable, Hashable, Sendable {
        public var channels: Channels = .stereo
        /// Also play the sound on the host's own speakers.
        public var playOnHost = false
        /// Send this Mac's microphone to the host.
        public var microphone = false
        public var volume: Double = 1
        /// The Mac's output to play the stream's sound on (a Core Audio device UID); nil follows the Mac's default
        /// output, including when it changes.
        public var outputDevice: String?
        /// Also send this Mac's microphone over VBAN while streaming (to VBAN Receptor, Voicemeeter…).
        public var vban = VBANSettings()
        public init() {}
        public enum Channels: String, Codable, CaseIterable, Sendable {
            case stereo, surround51, surround71
            public var title: String { switch self { case .stereo: "Stereo"; case .surround51: "5.1 surround"; case .surround71: "7.1 surround" } }
            public var count: Int { switch self { case .stereo: 2; case .surround51: 6; case .surround71: 8 } }
        }
    }

    public struct Controller: Codable, Hashable, Sendable {
        /// A Nokcandu controller profile to map the controller with, or nil for the controller as it is.
        public var profileID: String?
        public var sendAs: SendAs = .automatic
        /// Each controller is its own player on the host; off sends them all as player one.
        public var multipleControllers = true
        /// Swap A/B and X/Y (for Nintendo layouts).
        public var swapFaceButtons = false
        /// Send the controller's gyro and accelerometer when the host asks for them (PlayStation and Switch pads).
        public var motion = true
        public init() {}

        public enum SendAs: String, Codable, CaseIterable, Sendable {
            /// Like the controller: PlayStation pads as DualShock/DualSense, Switch pads as Switch, others as Xbox.
            case automatic
            case xbox, playstation, nintendo
            /// No controller reaches the host: only what a Nokcandu profile turns into keys, mouse and scrolling.
            case profileOnly
            public var title: String {
                switch self {
                case .automatic: "Automatic"
                case .xbox: "Xbox controller"
                case .playstation: "PlayStation controller"
                case .nintendo: "Switch Pro Controller"
                case .profileOnly: "No controller"
                }
            }
        }
    }

    public struct Input: Codable, Hashable, Sendable {
        public var mouse: Mouse = .capture
        public var reverseScroll = false
        /// Send ⌘ as the Windows key and keep Mac shortcuts (⌘Tab, ⌘Space…) on the host while the stream is in front.
        public var commandAsWindowsKey = true
        /// Swap ⌥ and ⌘ (so ⌥ is Windows and ⌘ is Alt).
        public var swapOptionCommand = false
        /// Turn off macOS's own keyboard shortcuts (⌘Tab, ⌘Space, ⌃←/⌃→, Mission Control…) while the stream is in
        /// front, so they reach the host instead.
        public var captureSystemShortcuts = true
        /// Share the clipboard with an Apollo host: the Mac's goes over when the stream comes to the front, the host's comes back when you leave it.
        /// Off by default until checked against Apollo (its secure port has stopped answering after streams).
        public var clipboard = false
        /// The keyboard layout (KeyRemap) used while the stream is in front: nil follows the default layout games
        /// use, "none" is normal keys, anything else a layout's ID.
        public var keyboardLayout: String?

        /// The remaps this stream applies.
        public func keyMappings(layouts: [KeyRemap.Layout] = KeyRemap.layouts(), defaultLayout: KeyRemap.Layout?? = nil) -> [KeyRemap.Mapping] {
            switch keyboardLayout {
            case nil: return (defaultLayout ?? KeyRemap.defaultLayout(layouts: layouts))?.mappings ?? []
            case "none"?: return []
            case let id?: return layouts.first { $0.id == id }?.mappings ?? []
            }
        }
        public init() {}
        public enum Mouse: String, Codable, CaseIterable, Sendable {
            /// The pointer is locked to the stream and sends movement (games, shooters).
            case capture
            /// The pointer moves over the stream as itself and sends its position (desktop use).
            case pointer
            public var title: String { switch self { case .capture: "Captured (for games)"; case .pointer: "Pointer (for the desktop)" } }
        }
    }

    public struct Window: Codable, Hashable, Sendable {
        public var fullScreen = true
        public var statistics: Statistics = .off
        /// The display the stream plays on (Core Graphics display UUID); nil is the one Nokcandu's window is on.
        public var display: String?
        /// Its name when chosen, to show while it isn't connected.
        public var displayName: String?
        public init() {}
        public enum Statistics: String, Codable, CaseIterable, Sendable {
            case off, basic, detailed
            public var title: String { switch self { case .off: "Off"; case .basic: "Frame rate and latency"; case .detailed: "Detailed" } }
        }
    }

    // Tolerant decoding: settings added later get their defaults.
    private enum CodingKeys: String, CodingKey { case id, hostID, name, appID, appName, route, video, audio, controller, input, window, optimizeGameSettings }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hostID = try c.decode(String.self, forKey: .hostID)
        name = try c.decode(String.self, forKey: .name)
        appID = try c.decodeIfPresent(Int.self, forKey: .appID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        route = (try? c.decodeIfPresent(Route.self, forKey: .route)) ?? .automatic
        video = (try? c.decodeIfPresent(Video.self, forKey: .video)) ?? Video()
        audio = (try? c.decodeIfPresent(Audio.self, forKey: .audio)) ?? Audio()
        controller = (try? c.decodeIfPresent(Controller.self, forKey: .controller)) ?? Controller()
        input = (try? c.decodeIfPresent(Input.self, forKey: .input)) ?? Input()
        window = (try? c.decodeIfPresent(Window.self, forKey: .window)) ?? Window()
        optimizeGameSettings = try c.decodeIfPresent(Bool.self, forKey: .optimizeGameSettings) ?? true
    }
}

extension StreamProfile.Video {
    private enum CodingKeys: String, CodingKey { case width, height, fps, bitrateKbps, codec, hdr, yuv444, pacing, fullRange, interpolation, upscaling, frameBuffer }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps)
        codec = (try? c.decodeIfPresent(Codec.self, forKey: .codec)) ?? .automatic
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
        yuv444 = try c.decodeIfPresent(Bool.self, forKey: .yuv444) ?? false
        pacing = (try? c.decodeIfPresent(Pacing.self, forKey: .pacing)) ?? .balanced
        fullRange = try c.decodeIfPresent(Bool.self, forKey: .fullRange) ?? false
        interpolation = try c.decodeIfPresent(Bool.self, forKey: .interpolation) ?? false
        upscaling = try c.decodeIfPresent(Bool.self, forKey: .upscaling) ?? false
        frameBuffer = (try c.decodeIfPresent(Int.self, forKey: .frameBuffer)).map { max(0, min(4, $0)) }
    }
}
extension StreamProfile.Audio {
    private enum CodingKeys: String, CodingKey { case channels, playOnHost, microphone, volume, vban, outputDevice }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        channels = (try? c.decodeIfPresent(Channels.self, forKey: .channels)) ?? .stereo
        playOnHost = try c.decodeIfPresent(Bool.self, forKey: .playOnHost) ?? false
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        vban = (try? c.decodeIfPresent(VBANSettings.self, forKey: .vban)) ?? VBANSettings()
        outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice)
    }
}
extension StreamProfile.Controller {
    private enum CodingKeys: String, CodingKey { case profileID, sendAs, multipleControllers, swapFaceButtons, motion }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
        sendAs = (try? c.decodeIfPresent(SendAs.self, forKey: .sendAs)) ?? .automatic
        multipleControllers = try c.decodeIfPresent(Bool.self, forKey: .multipleControllers) ?? true
        swapFaceButtons = try c.decodeIfPresent(Bool.self, forKey: .swapFaceButtons) ?? false
        motion = try c.decodeIfPresent(Bool.self, forKey: .motion) ?? true
    }
}
extension StreamProfile.Input {
    private enum CodingKeys: String, CodingKey { case mouse, reverseScroll, commandAsWindowsKey, swapOptionCommand, captureSystemShortcuts, clipboard, keyboardLayout }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mouse = (try? c.decodeIfPresent(Mouse.self, forKey: .mouse)) ?? .capture
        reverseScroll = try c.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? false
        commandAsWindowsKey = try c.decodeIfPresent(Bool.self, forKey: .commandAsWindowsKey) ?? true
        swapOptionCommand = try c.decodeIfPresent(Bool.self, forKey: .swapOptionCommand) ?? false
        captureSystemShortcuts = try c.decodeIfPresent(Bool.self, forKey: .captureSystemShortcuts) ?? true
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? false
        keyboardLayout = try c.decodeIfPresent(String.self, forKey: .keyboardLayout)
    }
}
extension StreamProfile.Window {
    private enum CodingKeys: String, CodingKey { case fullScreen, statistics, display, displayName }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? true
        statistics = (try? c.decodeIfPresent(Statistics.self, forKey: .statistics)) ?? .off
        display = try c.decodeIfPresent(String.self, forKey: .display)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }
}

/// Every host and stream profile, kept in Application Support/Nokcandu/streams.json.
public struct StreamLibrary: Codable, Equatable, Sendable {
    public var hosts: [StreamHost] = []
    public var profiles: [StreamProfile] = []
    public init() {}

    public static var file: URL { NokPaths.support.appendingPathComponent("streams.json") }

    public static func load(from url: URL = file) -> StreamLibrary {
        guard let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(StreamLibrary.self, from: data) else { return StreamLibrary() }
        return lib
    }
    public func save(to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public func profiles(for host: String) -> [StreamProfile] { profiles.filter { $0.hostID == host } }

    /// Adds or updates a host from what it said about itself. Known by its unique ID, or else by an address
    /// (the placeholder made when it was added by hand).
    @discardableResult
    public mutating func merge(_ info: StreamServerInfo, reachedAt address: String, placeholder: String? = nil) -> String {
        let i = hosts.firstIndex { $0.id == info.uniqueID } ?? placeholder.flatMap { p in hosts.firstIndex { $0.id == p } }
        var h = i.map { hosts[$0] } ?? StreamHost(id: info.uniqueID, name: info.hostname)
        let oldID = h.id
        h.id = info.uniqueID
        if !info.hostname.isEmpty { h.name = info.hostname }
        if StreamAddress.isPrivate(address) || address == info.localIP { h.localAddress = address }
        else if h.manualAddress == nil { h.manualAddress = address }
        if let ext = info.externalIP, !ext.isEmpty, !StreamAddress.isPrivate(ext) { h.remoteAddress = ext }
        if let mac = info.macAddress, mac != "00:00:00:00:00:00" { h.macAddress = mac }
        if info.httpsPort > 0 { h.httpsPort = info.httpsPort }
        h.capabilities.appVersion = info.appVersion
        h.capabilities.gfeVersion = info.gfeVersion
        h.capabilities.codecModes = info.codecModes
        h.capabilities.maxLumaPixelsHEVC = info.maxLumaPixelsHEVC
        // The saved pairing is never dropped here: a check that fails (a busy host, a network hiccup) must not
        // cost a PIN. A host that really forgot us says so (certificateRejected) and the user pairs again.
        if let i { hosts[i] = h } else { hosts.append(h) }
        if oldID != h.id { for j in profiles.indices where profiles[j].hostID == oldID { profiles[j].hostID = h.id } }
        return h.id
    }

    public mutating func removeHost(_ id: String) {
        hosts.removeAll { $0.id == id }
        profiles.removeAll { $0.hostID == id }
    }

    /// A first profile for a newly paired host: its desktop (or first app), this Mac's display, 60 fps.
    public mutating func addStarterProfile(for hostID: String) -> StreamProfile? {
        guard let h = hosts.first(where: { $0.id == hostID }), profiles(for: hostID).isEmpty else { return nil }
        var p = StreamProfile(hostID: hostID, name: "Home")
        let app = h.apps.first { $0.name.localizedCaseInsensitiveContains("desktop") } ?? h.apps.first
        p.appID = app?.id; p.appName = app?.name
        profiles.append(p)
        return p
    }
}

public enum StreamAddress {
    /// Splits "host", "host:port", "[v6]:port" or a bare IPv6 literal.
    public static func split(_ s: String) -> (host: String, port: UInt16?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil)
        }
        if t.filter({ $0 == ":" }).count == 1, let colon = t.lastIndex(of: ":") {
            return (String(t[..<colon]), UInt16(t[t.index(after: colon)...]))
        }
        return (t, nil)
    }

    /// Private, link-local or loopback IPv4/IPv6 addresses (a host on this network).
    public static func isPrivate(_ s: String) -> Bool {
        let h = split(s).host.lowercased()
        let p = h.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
                || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && (64...127).contains(p[1]))
        }
        if h.contains(":") { return h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") || h == "::1" }
        return h.hasSuffix(".local") || !h.contains(".")
    }
}
