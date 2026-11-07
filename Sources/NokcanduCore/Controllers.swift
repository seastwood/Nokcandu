import Foundation
import IOKit.hid

/// How game controllers reach Windows programs.
///
/// Wine's controller driver (winebus) can hand Windows a controller two ways: converted to an Xbox controller
/// (every game understands it, but gyro, touchpads, paddles and extra buttons are lost), or passed through as the
/// real device ("hidraw": Windows sees the actual Switch Pro Controller, DualSense…, with all its features, but
/// only programs that know that controller can use it — Steam's own controller support does). Wine passes
/// PlayStation controllers through by default and converts everything else.
///
/// The choice is per Windows environment (all games in a shared Steam or Battle.net share one) and is written to
/// winebus's per-maker registry keys (HKLM\System\CurrentControlSet\Services\WineBus\Devices\<vid>, value
/// Hidraw), only while that environment is closed; Wine reads them when it starts.
public enum Controllers {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic, native, xbox
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .native: "As itself"
            case .xbox: "As an Xbox controller"
            }
        }
    }

    /// Controller makers with their own Windows support worth passing through.
    public enum Family: String, CaseIterable, Sendable {
        case nintendo, playstation, valve
        public var vendorID: Int { switch self { case .nintendo: 0x057E; case .playstation: 0x054C; case .valve: 0x28DE } }
        public var title: String { switch self { case .nintendo: "Nintendo"; case .playstation: "PlayStation"; case .valve: "Steam" } }
        public static func of(vendorID: Int) -> Family? { allCases.first { $0.vendorID == vendorID } }
    }

    // MARK: The environment's choice

    static func settingsURL(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/controllers.json") }
    struct Saved: Codable { var mode: Mode }

    public static func mode(contents: URL) -> Mode {
        (try? Data(contentsOf: settingsURL(contents))).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }?.mode ?? .automatic
    }

    /// Steam's environment: Steam's own controller support handles controllers as themselves (gyro, trackpads…).
    public static func isSteamEnvironment(_ contents: URL) -> Bool {
        contents.standardizedFileURL == SharedSteam.contents.standardizedFileURL || SharedSteam.isHost(contents: contents)
    }

    /// Passed through (true), converted (false) or Wine's default (nil) for each maker, for a mode.
    public static func plan(_ mode: Mode, steam: Bool) -> [Family: Bool?] {
        switch mode {
        case .native: return Dictionary(uniqueKeysWithValues: Family.allCases.map { ($0, true) })
        case .xbox: return Dictionary(uniqueKeysWithValues: Family.allCases.map { ($0, false) })
        case .automatic:
            return steam ? Dictionary(uniqueKeysWithValues: Family.allCases.map { ($0, true) })
                         : Dictionary(uniqueKeysWithValues: Family.allCases.map { ($0, Optional<Bool>.none) })
        }
    }

    /// How a controller of this maker reaches Windows in this environment.
    public static func passesThrough(_ family: Family?, mode: Mode, steam: Bool) -> Bool {
        guard let family else { return false }
        if let decided = plan(mode, steam: steam)[family] ?? nil { return decided }
        return family == .playstation      // Wine's default
    }

    static func registryKey(_ f: Family) -> String {
        #"System\\CurrentControlSet\\Services\\WineBus\\Devices\\"# + String(format: "%04x", f.vendorID)
    }

    /// Saves and applies the choice. The environment must be closed (Wine rewrites its registry while running).
    public static func set(_ mode: Mode, contents: URL) throws {
        guard WineTools.ownedProcesses(contents: contents).isEmpty else {
            throw NokError("Quit the games and launcher using this Windows environment first; controllers are set up when it starts.")
        }
        let system = contents.appendingPathComponent("SharedSupport/prefix/system.reg")
        guard FileManager.default.fileExists(atPath: system.path) else { throw NokError("This Windows environment hasn't been set up yet.") }
        try apply(plan(effective(mode, contents: contents), steam: isSteamEnvironment(contents)), system: system)
        try NokPaths.ensure(settingsURL(contents).deletingLastPathComponent())
        try JSONEncoder().encode(Saved(mode: mode)).write(to: settingsURL(contents), options: .atomic)
    }

    static func apply(_ plan: [Family: Bool?], system: URL) throws {
        for f in Family.allCases {
            let key = registryKey(f)
            if let on = plan[f] ?? nil {
                _ = try RegistryText.set(system, key: key, name: "Hidraw", value: String(format: "dword:%08x", on ? 1 : 0)) { _ in true }
            } else {
                _ = try RegistryText.remove(system, key: key, name: "Hidraw")
            }
        }
    }

    /// With a controller profile in use, every controller goes through Wine's SDL driver (where the profile is
    /// applied) and reaches the game as an Xbox controller.
    public static func effective(_ mode: Mode, contents: URL) -> Mode { PadProfiles.inUse(contents: contents) ? .xbox : mode }

    /// Re-applies a saved choice (and a controller profile's needs) when the registry is out of step — after Repair,
    /// or a profile set while the game was open. Only while the environment is closed; cheap when nothing changes.
    public static func refresh(contents: URL) {
        let system = contents.appendingPathComponent("SharedSupport/prefix/system.reg")
        let saved = FileManager.default.fileExists(atPath: settingsURL(contents).path)
        let profile = PadProfiles.inUse(contents: contents)
        let marker = contents.appendingPathComponent("SharedSupport/nokcandu/controllers-applied")
        let want = "\(effective(mode(contents: contents), contents: contents).rawValue)"
        guard saved || profile || FileManager.default.fileExists(atPath: marker.path),
              (try? String(contentsOf: marker, encoding: .utf8)) != want,
              FileManager.default.fileExists(atPath: system.path),
              WineTools.ownedProcesses(contents: contents).isEmpty else { return }
        if (try? apply(plan(effective(mode(contents: contents), contents: contents), steam: isSteamEnvironment(contents)), system: system)) != nil {
            try? Data(want.utf8).write(to: marker, options: .atomic)
        }
    }

    // MARK: What's plugged in

    public struct Connected: Identifiable, Hashable, Sendable {
        public var id: String { "\(vendorID):\(productID):\(location)" }
        public var name: String
        public var vendorID: Int
        public var productID: Int
        public var location: Int
        public var bluetooth: Bool
        /// It reports itself as a joystick or gamepad. Wine's Mac controller driver only takes those
        /// (the original Steam Controller presents keyboard, mouse and a Valve-specific interface instead).
        public var isGamepad: Bool
        /// Its primary usage page (1 generic desktop, 2 simulation controls).
        public var usagePage: Int = 1
        public var usage: Int = 0
        public var family: Family? { Family.of(vendorID: vendorID) }
        public var kind: Kind { Controllers.kind(vendorID: vendorID, productID: productID, usagePage: usagePage, usage: usage) }
        public var hasMotion: Bool {
            switch family {
            case .nintendo: return [0x2006, 0x2007, 0x2009, 0x200E, 0x2066, 0x2067, 0x2069].contains(productID)
            case .playstation: return true
            case .valve: return true
            case nil: return false
            }
        }
        public var ids: String { String(format: "%04X:%04X", vendorID, productID) }
    }

    public enum Kind: String, Sendable {
        case gamepad, wheel, flight, joystick
        public var title: String {
            switch self { case .gamepad: "Controller"; case .wheel: "Racing wheel or pedals"; case .flight: "Flight controls"; case .joystick: "Joystick" }
        }
        public var symbol: String {
            switch self { case .gamepad: "gamecontroller"; case .wheel: "steeringwheel"; case .flight: "airplane"; case .joystick: "arcade.stick" }
        }
    }

    /// Racing and flight gear makers (and the wheel/flight ranges of makers that also sell other things).
    static let wheelMakers: Set<Int> = [0x0EB7 /* Fanatec */, 0x346E /* Moza */, 0x3670 /* Simagic */, 0x3416 /* Cammus */, 0x16D0 /* Simucube */, 0x30B7 /* Heusinkveld */, 0x1DD2 /* Leo Bodnar */]
    static let flightMakers: Set<Int> = [0x231D /* VKB */, 0x3344 /* Virpil */, 0x294B /* Honeycomb */, 0x4098 /* WinWing */, 0x068E /* CH Products */, 0x06A3 /* Saitek */, 0x0738 /* Mad Catz */, 0x10F5 /* Turtle Beach */]
    static let logitechWheels: Set<Int> = [0xC294, 0xC295, 0xC298, 0xC299, 0xC29A, 0xC29B, 0xC24F, 0xC260, 0xC261, 0xC262, 0xC266, 0xC267, 0xC26D, 0xC26E, 0xC268, 0xC272]
    static let logitechFlight: Set<Int> = [0xC215, 0xC21A, 0xC21C, 0xC287, 0xC286, 0x0A38, 0xC2AB, 0xC2A8, 0xC2A9]

    static func kind(vendorID v: Int, productID p: Int, usagePage: Int, usage: Int) -> Kind {
        if wheelMakers.contains(v) { return .wheel }
        if flightMakers.contains(v) { return .flight }
        if v == 0x046D { if logitechWheels.contains(p) { return .wheel }; if logitechFlight.contains(p) { return .flight } }
        if v == 0x044F {                                    // Thrustmaster: wheels are B6xx, flight sticks/throttles/pedals the rest
            if (0xB650...0xB6FF).contains(p) && ![0xB679, 0xB687].contains(p) { return .wheel }
            return usage == kHIDUsage_GD_GamePad ? .gamepad : .flight
        }
        if usagePage == 2 { return usage == 0x02 ? .wheel : .flight }       // simulation controls: automobile / flight…
        if usage == kHIDUsage_GD_Joystick || usage == kHIDUsage_GD_MultiAxisController { return .joystick }
        return .gamepad
    }

    /// Game controllers connected to this Mac (reads their descriptions; nothing is opened).
    public static func connected() -> [Connected] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
            [kIOHIDVendorIDKey: Family.valve.vendorID],
            [kIOHIDDeviceUsagePageKey: 0x02],                                // simulation controls (some pedals, yokes, panels)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        func int(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ d: IOHIDDevice, _ k: String) -> String? { IOHIDDeviceGetProperty(d, k as CFString) as? String }
        var byDevice: [String: Connected] = [:]
        for d in set {
            let page = int(d, kIOHIDPrimaryUsagePageKey), usage = int(d, kIOHIDPrimaryUsageKey)
            // What Wine takes on the Mac: generic-desktop gamepads and joysticks (and multi-axis controllers, through SDL).
            let gamepad = page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_GamePad || usage == kHIDUsage_GD_Joystick || usage == kHIDUsage_GD_MultiAxisController)
            let transport = str(d, kIOHIDTransportKey)?.lowercased() ?? ""
            let c = Connected(name: str(d, kIOHIDProductKey) ?? "Controller", vendorID: int(d, kIOHIDVendorIDKey), productID: int(d, kIOHIDProductIDKey),
                              location: int(d, kIOHIDLocationIDKey), bluetooth: transport.contains("bluetooth"), isGamepad: gamepad,
                              usagePage: page, usage: usage)
            // One physical controller can show several interfaces (the Steam Controller's keyboard and mouse); keep one.
            let key = "\(c.vendorID):\(c.productID):\(c.location)"
            if let existing = byDevice[key], existing.isGamepad || !c.isGamepad { continue }
            byDevice[key] = c
        }
        return byDevice.values.sorted { $0.name < $1.name }
    }

    /// How this controller reaches Windows programs here, in words.
    public static func describe(_ c: Connected, mode: Mode, steam: Bool) -> String {
        guard c.isGamepad else {
            return "Not seen by Windows programs yet: Wine on the Mac only takes devices that present themselves as gamepads or joysticks."
        }
        if c.family == nil, c.kind != .gamepad {
            // Wheels, pedals and flight gear keep their own axes and buttons (Wine passes many through as the real device).
            return "As itself: its own axes and buttons, for games with \(c.kind == .wheel ? "wheel" : "joystick") support."
        }
        if passesThrough(c.family, mode: mode, steam: steam) {
            return "As itself" + (c.hasMotion ? ", with gyro" : "") + (steam ? ". Steam Input handles it; set it up in Steam's controller settings." : ". Only games that support this controller can use it.")
        }
        return "As an Xbox controller" + (c.hasMotion ? " (gyro isn't passed on this way)" : "") + "."
    }
}
