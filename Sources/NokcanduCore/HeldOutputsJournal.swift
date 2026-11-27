// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The keys and mouse buttons Nokcandu is holding down in macOS, kept in a small file as they change. macOS keeps a
/// posted key or button down until it's released, so if Nokcandu quits without releasing them (a crash, a forced
/// quit, an update's restart), they stay stuck until pressed again. The next launch releases whatever the file
/// says was held, then empties it.
public struct HeldOutputsJournal: Codable, Equatable, Sendable {
    public var keys: Set<Int> = []
    public var mouseButtons: Set<Int> = []
    public init() {}

    public var isEmpty: Bool { keys.isEmpty && mouseButtons.isEmpty }

    /// Records a change; true if the held set changed (worth saving).
    public mutating func key(_ k: Int, down: Bool) -> Bool { down ? keys.insert(k).inserted : keys.remove(k) != nil }
    public mutating func mouse(_ b: Int, down: Bool) -> Bool { down ? mouseButtons.insert(b).inserted : mouseButtons.remove(b) != nil }

    public static var file: URL { NokPaths.support.appendingPathComponent("held-outputs.json") }

    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    /// What a journal file says, ignoring anything unreadable or implausible (only real key codes and buttons).
    public static func read(_ data: Data?) -> HeldOutputsJournal {
        guard let data, data.count < 64 * 1024, var j = try? JSONDecoder().decode(HeldOutputsJournal.self, from: data) else { return HeldOutputsJournal() }
        j.keys = j.keys.filter { (0..<256).contains($0) }
        j.mouseButtons = j.mouseButtons.filter { (0..<32).contains($0) }
        return j
    }
}
