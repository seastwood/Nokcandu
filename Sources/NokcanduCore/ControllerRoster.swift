// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Every controller Nokcandu has seen, remembered between connections: its name, which player it is, and the
/// profile it falls back to. Two identical controllers stay apart by their serial number (a Bluetooth controller's is
/// its address); one without a usable serial is told apart from its twins only by the order they were connected.
public struct ControllerRoster: Codable, Equatable, Sendable {
    public var controllers: [Remembered] = []
    public init(controllers: [Remembered] = []) { self.controllers = controllers }

    /// Which player a controller is.
    public enum Seat: Codable, Hashable, Sendable {
        /// The next free player, in the order controllers connect.
        case auto
        /// Always this player (1–8). Several controllers on one player drive it together.
        case player(Int)

        public var title: String {
            switch self { case .auto: "Auto"; case .player(let n): "Player \(n)" }
        }
        public var explicit: Int? { if case .player(let n) = self { return n }; return nil }
    }

    public struct Remembered: Codable, Identifiable, Equatable, Sendable {
        public var id: String { key }
        public var key: String
        public var vendorID: Int
        public var productID: Int
        /// The product name the controller gives itself.
        public var productName: String
        /// A name the person gave it ("Seth's Pro"); nil: the product name.
        public var customName: String?
        public var seat: Seat = .auto
        /// The profile it uses in apps and games that have no profile of their own choice (nil: none).
        public var fallbackProfileID: String?
        /// It has no serial of its own: twins can trade places if they're reconnected in the other order.
        public var byOrder: Bool
        public var lastSeen: Date

        public var name: String { customName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? productName }

        public init(key: String, vendorID: Int, productID: Int, productName: String, customName: String? = nil, seat: Seat = .auto,
                    fallbackProfileID: String? = nil, byOrder: Bool, lastSeen: Date = Date()) {
            self.key = key; self.vendorID = vendorID; self.productID = productID; self.productName = productName
            self.customName = customName; self.seat = seat; self.fallbackProfileID = fallbackProfileID; self.byOrder = byOrder; self.lastSeen = lastSeen
        }
    }

    // MARK: Identity

    /// A serial number in a form both macOS and SDL agree on: letters and digits only, lowercased ("A4-AE-12…" and
    /// "a4ae12…" are the same controller). Nil when there's none worth trusting: empty, or a placeholder some
    /// controllers report (all zeros, one repeated character).
    public static func normalizedSerial(_ s: String?) -> String? {
        guard let s else { return nil }
        let n = String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
        guard n.count >= 6 else { return nil }
        let digits = Set(n)
        if digits.count == 1 { return nil }
        // "000000000001": a counter, not a serial.
        if n.dropLast().allSatisfy({ $0 == "0" }) { return nil }
        return n
    }

    /// A controller's remembered key: its maker and model codes, and its serial, or without one its place among
    /// identical controllers (0 first).
    public static func key(vendorID: Int, productID: Int, serial: String?, nth: Int) -> String {
        let base = String(format: "%04x:%04x", vendorID & 0xFFFF, productID & 0xFFFF)
        if let s = normalizedSerial(serial) { return base + ":s:" + s }
        return base + ":n:\(nth)"
    }

    public func controller(_ key: String) -> Remembered? { controllers.first { $0.key == key } }

    /// Notes a connected controller (adding it the first time) and returns its key.
    @discardableResult
    public mutating func saw(vendorID: Int, productID: Int, serial: String?, nth: Int, name: String, at date: Date = Date()) -> String {
        let k = Self.key(vendorID: vendorID, productID: productID, serial: serial, nth: nth)
        if let i = controllers.firstIndex(where: { $0.key == k }) {
            controllers[i].lastSeen = date
            if controllers[i].productName != name, !name.isEmpty { controllers[i].productName = name }
        } else {
            controllers.append(Remembered(key: k, vendorID: vendorID, productID: productID, productName: name,
                                          byOrder: Self.normalizedSerial(serial) == nil, lastSeen: date))
        }
        return k
    }

    /// Notes a controller known only by a key of Nokcandu's making (one of its own USB drivers' controllers).
    @discardableResult
    public mutating func saw(key k: String, name: String, at date: Date = Date()) -> String {
        if let i = controllers.firstIndex(where: { $0.key == k }) { controllers[i].lastSeen = date }
        else { controllers.append(Remembered(key: k, vendorID: 0, productID: 0, productName: name, byOrder: true, lastSeen: date)) }
        return k
    }

    public mutating func update(_ key: String, _ change: (inout Remembered) -> Void) {
        guard let i = controllers.firstIndex(where: { $0.key == key }) else { return }
        change(&controllers[i])
    }
    public mutating func forget(_ key: String) { controllers.removeAll { $0.key == key } }

    // MARK: Players

    /// The player each connected controller is (keys in the order they connected). Controllers set to a player
    /// keep it (several may share one); Auto ones take the lowest players nobody chose, in connection order.
    public func players(connected keys: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        var taken = Set<Int>()
        for k in keys { if let n = controller(k)?.seat.explicit { result[k] = n; taken.insert(n) } }
        var next = 1
        for k in keys where result[k] == nil {
            while taken.contains(next) { next += 1 }
            result[k] = next; taken.insert(next)
        }
        return result
    }

    // MARK: Profiles

    /// Why a controller gets the profile it gets.
    public enum Reason: Equatable, Sendable {
        case everywhere                 // "Use a profile everywhere" is on
        case gameForController(String)  // the game's choice for this controller (game name)
        case game(String)               // the game's profile
        case gameNone(String)           // the game uses controllers as they are
        case controllerFallback         // this controller's own fallback
        case app(String)                // the app's rule
        case macDefault                 // the Mac's profile
        case none

        public var words: String {
            switch self {
            case .everywhere: "used everywhere"
            case .gameForController(let g): "\(g)'s choice for this controller"
            case .game(let g): "\(g)'s profile"
            case .gameNone(let g): "\(g) uses controllers as they are"
            case .controllerFallback: "this controller's own profile"
            case .app(let a): "the rule for \(a)"
            case .macDefault: "the Mac's profile"
            case .none: "no profile applies"
            }
        }
    }

    /// The profile a controller gets, in one fixed order: a profile used everywhere; then in a game, the game's choice
    /// for this controller, then the game's profile (a game without one keeps controllers as they are); elsewhere,
    /// the app's rule, then the controller's own profile, then the Mac's.
    public static func resolve(everywhere: String?, game: String?, gameForController: String?, gameProfile: String?,
                               appName: String?, appRule: String?, controllerFallback: String?, macDefault: String?) -> (id: String?, reason: Reason) {
        if let everywhere { return (everywhere, .everywhere) }
        if let game {
            if let c = gameForController { return (c, .gameForController(game)) }
            if let p = gameProfile { return (p, .game(game)) }
            return (nil, .gameNone(game))
        }
        if let appRule { return appRule == "off" ? (nil, .app(appName ?? "this app")) : (appRule, .app(appName ?? "this app")) }
        if let controllerFallback { return (controllerFallback, .controllerFallback) }
        if let macDefault { return (macDefault, .macDefault) }
        return (nil, .none)
    }

    // MARK: Windows games

    /// A connected controller as Windows games' controller driver finds it.
    public struct Connected: Equatable, Sendable {
        public var key: String, registryID: UInt64, vendorID: Int, productID: Int, serial: String?, nth: Int
        public init(key: String, registryID: UInt64, vendorID: Int, productID: Int, serial: String?, nth: Int) {
            self.key = key; self.registryID = registryID; self.vendorID = vendorID; self.productID = productID; self.serial = serial; self.nth = nth
        }
    }

    /// The players file Windows games' controller driver reads: one line per controller set to a player,
    /// "c <registry id> <vendor> <product> <serial or -> <nth> <player> <key>" (player 0: Auto). The driver matches a
    /// controller by its connection (registry id), then serial, then model and place.
    public func playersText(connected: [Connected]) -> String {
        var t = "nokplayers 1\n"
        for c in connected {
            let seat = controller(c.key)?.seat.explicit ?? 0
            t += "c \(c.registryID) \(c.vendorID) \(c.productID) \(Self.normalizedSerial(c.serial) ?? "-") \(c.nth) \(seat) \(c.key)\n"
        }
        return t
    }

    /// What a Windows game's driver reported: the player each controller became ("<key> <player>" lines, after
    /// "pid <driver's process>").
    public static func parseSeen(_ text: String) -> [String: Int] {
        var r: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let w = line.split(separator: " ")
            if w.count == 2, w[0] != "pid", let n = Int(w[1]) { r[String(w[0])] = n }
        }
        return r
    }
    /// The driver process that wrote a players report (gone: the report is old).
    public static func seenProcess(_ text: String) -> Int32? {
        guard let first = text.split(separator: "\n").first, first.hasPrefix("pid ") else { return nil }
        return Int32(first.dropFirst(4))
    }

    // MARK: Storage

    public static var file: URL { NokPaths.support.appendingPathComponent("controllers.json") }
    public static var playersFile: URL { NokPaths.support.appendingPathComponent("controller-players") }

    public static func load(from f: URL = file) -> ControllerRoster {
        guard let d = try? Data(contentsOf: f) else { return ControllerRoster() }
        return (try? JSONDecoder().decode(ControllerRoster.self, from: d)) ?? ControllerRoster()
    }
    public func save(to f: URL = file) {
        try? NokPaths.ensure(f.deletingLastPathComponent())
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: f, options: .atomic) }
    }
}
