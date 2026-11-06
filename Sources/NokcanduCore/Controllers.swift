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
        try apply(plan(mode, steam: isSteamEnvironment(contents)), system: system)
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

    /// Re-applies a saved choice when Nokcandu finds the registry out of step (for example after Repair), while closed.
    public static func refresh(contents: URL) {
        guard FileManager.default.fileExists(atPath: settingsURL(contents).path),
              WineTools.ownedProcesses(contents: contents).isEmpty else { return }
        try? apply(plan(mode(contents: contents), steam: isSteamEnvironment(contents)),
                   system: contents.appendingPathComponent("SharedSupport/prefix/system.reg"))
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
        public var family: Family? { Family.of(vendorID: vendorID) }
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

    /// Game controllers connected to this Mac (reads their descriptions; nothing is opened).
    public static func connected() -> [Connected] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
            [kIOHIDVendorIDKey: Family.valve.vendorID],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        func int(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ d: IOHIDDevice, _ k: String) -> String? { IOHIDDeviceGetProperty(d, k as CFString) as? String }
        var byDevice: [String: Connected] = [:]
        for d in set {
            let page = int(d, kIOHIDPrimaryUsagePageKey), usage = int(d, kIOHIDPrimaryUsageKey)
            let gamepad = page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_GamePad || usage == kHIDUsage_GD_Joystick)
            let transport = str(d, kIOHIDTransportKey)?.lowercased() ?? ""
            let c = Connected(name: str(d, kIOHIDProductKey) ?? "Controller", vendorID: int(d, kIOHIDVendorIDKey), productID: int(d, kIOHIDProductIDKey),
                              location: int(d, kIOHIDLocationIDKey), bluetooth: transport.contains("bluetooth"), isGamepad: gamepad)
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
            return "Not seen by Windows programs yet: Wine on the Mac only takes controllers that present themselves as gamepads."
        }
        if passesThrough(c.family, mode: mode, steam: steam) {
            return "As itself" + (c.hasMotion ? ", with gyro" : "") + (steam ? ". Steam Input handles it; set it up in Steam's controller settings." : ". Only games that support this controller can use it.")
        }
        return "As an Xbox controller" + (c.hasMotion ? " (gyro isn't passed on this way)" : "") + "."
    }
}
