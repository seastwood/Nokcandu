import Foundation

/// Per-game key remapping (instead of a system-wide remapper like Karabiner-Elements). While the game is in front,
/// Nokcandu's helper inside it swaps the chosen keys with macOS's own keyboard remapping (hidutil), and puts the
/// keyboard back when you switch away or the game quits. Kept per Windows environment ("key-remap" in its state
/// folder, beside the helper), like raw mouse capture. Keys are stored as HID usages (page 7 keyboard keys, and
/// Apple's fn key), the form macOS's remapping takes.
public enum KeyRemap {
    public struct Key: Hashable, Identifiable, Sendable {
        public var code: Int
        public var title: String
        /// Karabiner-Elements' name for it ("left_control"), for importing.
        public var karabiner: String
        public var id: Int { code }
    }

    /// Keys that can be remapped (Mac virtual key codes).
    public static let keys: [Key] = {
        var k: [Key] = [
            Key(code: 59, title: "Left Control", karabiner: "left_control"), Key(code: 62, title: "Right Control", karabiner: "right_control"),
            Key(code: 58, title: "Left Option", karabiner: "left_option"), Key(code: 61, title: "Right Option", karabiner: "right_option"),
            Key(code: 55, title: "Left Command", karabiner: "left_command"), Key(code: 54, title: "Right Command", karabiner: "right_command"),
            Key(code: 56, title: "Left Shift", karabiner: "left_shift"), Key(code: 60, title: "Right Shift", karabiner: "right_shift"),
            Key(code: 63, title: "fn", karabiner: "fn"), Key(code: 57, title: "Caps Lock", karabiner: "caps_lock"),
            Key(code: 49, title: "Space", karabiner: "spacebar"), Key(code: 48, title: "Tab", karabiner: "tab"),
            Key(code: 36, title: "Return", karabiner: "return_or_enter"), Key(code: 53, title: "Escape", karabiner: "escape"),
            Key(code: 51, title: "Delete", karabiner: "delete_or_backspace"), Key(code: 117, title: "Forward Delete", karabiner: "delete_forward"),
            Key(code: 50, title: "` (Grave)", karabiner: "grave_accent_and_tilde"), Key(code: 10, title: "§ (Section)", karabiner: "non_us_backslash"),
            Key(code: 123, title: "Left Arrow", karabiner: "left_arrow"), Key(code: 124, title: "Right Arrow", karabiner: "right_arrow"),
            Key(code: 125, title: "Down Arrow", karabiner: "down_arrow"), Key(code: 126, title: "Up Arrow", karabiner: "up_arrow"),
            Key(code: 115, title: "Home", karabiner: "home"), Key(code: 119, title: "End", karabiner: "end"),
            Key(code: 116, title: "Page Up", karabiner: "page_up"), Key(code: 121, title: "Page Down", karabiner: "page_down"),
        ]
        let letters: [(String, Int)] = [("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7), ("C", 8), ("V", 9),
                                        ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("Y", 16), ("T", 17), ("O", 31), ("U", 32),
                                        ("I", 34), ("P", 35), ("L", 37), ("J", 38), ("K", 40), ("N", 45), ("M", 46)]
        k += letters.sorted { $0.0 < $1.0 }.map { Key(code: $0.1, title: $0.0, karabiner: $0.0.lowercased()) }
        let digits: [(String, Int)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        k += digits.map { Key(code: $0.1, title: $0.0, karabiner: $0.0) }
        let fkeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        k += fkeys.enumerated().map { Key(code: $0.element, title: "F\($0.offset + 1)", karabiner: "f\($0.offset + 1)") }
        return k
    }()
    public static func key(_ code: Int) -> Key? { keys.first { $0.code == code } }

    /// HID usage (as macOS's keyboard remapping takes it) for a Mac key code.
    static let hidUsages: [Int: UInt64] = {
        var u: [Int: UInt64] = [59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7, 57: 0x39,
                                49: 0x2C, 48: 0x2B, 36: 0x28, 53: 0x29, 51: 0x2A, 117: 0x4C, 50: 0x35, 10: 0x64,
                                124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52, 115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E]
        let letters: [Int] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]   // A…Z
        for (i, code) in letters.enumerated() { u[code] = 0x04 + UInt64(i) }
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]                                                    // 1…9, 0
        for (i, code) in digits.enumerated() { u[code] = 0x1E + UInt64(i) }
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { u[code] = 0x3A + UInt64(i) }
        var out = u.mapValues { 0x7_0000_0000 | $0 }
        out[63] = 0xFF01_0000_0003                                                                               // fn (Globe)
        return out
    }()
    /// A key that does nothing (keyboard usage 0: no event).
    static let nothingUsage: UInt64 = 0x7_0000_0000

    /// One remap: `from` acts as `to` (nil: does nothing).
    public struct Mapping: Hashable, Identifiable, Sendable {
        public var from: Int
        public var to: Int?
        public var id: Int { from }
        public init(from: Int, to: Int?) { self.from = from; self.to = to }
    }

    static func folder(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }
    static func file(_ contents: URL) -> URL { folder(contents).appendingPathComponent("key-remap") }
    /// Same scope as raw mouse capture: the game's own environment, or its launcher's.
    public static func contents(for g: InstalledGame) -> URL? { WineTools.hostContents(for: g) }

    public static func load(contents: URL) -> [Mapping] {
        guard let text = try? String(contentsOf: file(contents), encoding: .utf8) else { return [] }
        return parse(text)
    }
    static func parse(_ text: String) -> [Mapping] {
        var seen = Set<Int>()
        let byUsage = Dictionary(hidUsages.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        return text.split(separator: "\n").compactMap { line -> Mapping? in
            let p = line.split(separator: " ").compactMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
            guard p.count == 2, let from = byUsage[p[0]], seen.insert(from).inserted else { return nil }
            if p[1] == nothingUsage { return Mapping(from: from, to: nil) }
            guard let to = byUsage[p[1]] else { return nil }
            return Mapping(from: from, to: to)
        }
    }
    static func text(_ m: [Mapping]) -> String {
        m.compactMap { x -> String? in
            guard let src = hidUsages[x.from] else { return nil }
            let dst = x.to.flatMap { hidUsages[$0] } ?? nothingUsage
            return String(format: "0x%llx 0x%llx", src, dst)
        }.joined(separator: "\n") + (m.isEmpty ? "" : "\n")
    }

    // MARK: A keyboard left remapped

    static var activeMarker: URL { NokPaths.support.appendingPathComponent("key-remap-active") }

    /// The game that remapped the keyboard is gone (it crashed or was force-quit) but its mapping is still on:
    /// put back the mapping that was there before. Cheap when nothing is remapped (one stat). Call off the main thread.
    @discardableResult
    public static func recoverIfStale() -> Bool {
        guard let text = try? String(contentsOf: activeMarker, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let pid = lines.first.flatMap({ Int32($0) }) else { try? FileManager.default.removeItem(at: activeMarker); return false }
        if pid > 1, kill(pid, 0) == 0 { return false }
        let previous = lines.count > 1 && lines[1].hasPrefix("[") ? String(lines[1]) : "[]"
        _ = try? Shell.run("/usr/bin/hidutil", ["property", "--set", "{\"UserKeyMapping\":\(previous)}"], timeout: 10)
        try? FileManager.default.removeItem(at: activeMarker)
        return true
    }
    public static func save(_ m: [Mapping], contents: URL) throws {
        let clean = m.filter { $0.to != $0.from }
        if clean.isEmpty { try? FileManager.default.removeItem(at: file(contents)); return }
        try NokPaths.ensure(folder(contents))
        try Data(text(clean).utf8).write(to: file(contents), options: .atomic)
    }

    // MARK: Importing Karabiner-Elements

    public struct KarabinerProfile: Identifiable, Equatable, Sendable {
        public var name: String
        public var selected: Bool
        public var mappings: [Mapping]
        /// Rules Nokcandu can't copy (complex modifications, mouse buttons, consumer keys…).
        public var skipped: Int
        public var id: String { name }
    }

    public static var karabinerConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
    }

    public static func karabinerProfiles(_ url: URL = karabinerConfig) -> [KarabinerProfile] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]] else { return [] }
        func code(_ side: [String: Any]?) -> Int?? {
            guard let side else { return nil }
            if let k = side["key_code"] as? String, k == "vk_none" { return .some(nil) }
            if let k = side["key_code"] as? String { return keys.first { $0.karabiner == k }.map { .some($0.code) } }
            if let k = side["apple_vendor_top_case_key_code"] as? String, k == "keyboard_fn" { return .some(63) }
            return nil
        }
        return profiles.map { p in
            var mappings: [Mapping] = [], skipped = 0
            var simple = (p["simple_modifications"] as? [[String: Any]]) ?? []
            // Modifications for one keyboard are included too (all keyboards are treated alike in games).
            for d in (p["devices"] as? [[String: Any]]) ?? [] { simple += (d["simple_modifications"] as? [[String: Any]]) ?? [] }
            for s in simple {
                let from = code(s["from"] as? [String: Any])
                let toList = s["to"] as? [[String: Any]] ?? []
                let to: Int?? = toList.isEmpty ? .some(nil) : toList.count == 1 ? code(toList[0]) : nil
                guard let f = from ?? nil, let t = to else { skipped += 1; continue }
                if !mappings.contains(where: { $0.from == f }) { mappings.append(Mapping(from: f, to: t)) }
            }
            skipped += ((p["complex_modifications"] as? [String: Any])?["rules"] as? [Any])?.count ?? 0
            return KarabinerProfile(name: p["name"] as? String ?? "Profile", selected: p["selected"] as? Bool ?? false,
                                    mappings: mappings, skipped: skipped)
        }
    }
}
