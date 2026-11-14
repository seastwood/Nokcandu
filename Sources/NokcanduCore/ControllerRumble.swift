// SPDX-License-Identifier: GPL-3.0-only
// Rumble a Windows game asks for, on a controller SDL can't rumble: the Wine helper (Resources/rawmouse/padmap.m)
// sends it here and Nokcandu plays it with the controller's own haptics.
import Foundation

public enum ControllerRumble {
    /// Where the Wine helper sends requests (a Unix datagram socket).
    public static var socketFile: URL { NokPaths.support.appendingPathComponent("controller-rumble.sock") }

    public struct Request: Equatable, Sendable {
        public var vendor: Int, product: Int
        /// 0…1: the low-frequency (strong) and high-frequency (weak) motors.
        public var low: Double, high: Double
        /// Milliseconds the game asked for; 0 when it gave none.
        public var milliseconds: Int
        public var name: String
        public var strength: Double { max(low, high) }

        /// "nokcandu-rumble 1 <vendor hex> <product hex> <low> <high> <ms> <name…>"
        public static func parse(_ text: String) -> Request? {
            let parts = text.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7, parts[0] == "nokcandu-rumble", parts[1] == "1",
                  let v = Int(parts[2], radix: 16), let p = Int(parts[3], radix: 16),
                  let lo = UInt16(parts[4]), let hi = UInt16(parts[5]), let ms = UInt32(parts[6]) else { return nil }
            return Request(vendor: v, product: p, low: Double(lo) / 65535, high: Double(hi) / 65535,
                           milliseconds: Int(min(ms, 600_000)), name: parts.count > 7 ? parts[7] : "")
        }
    }

    /// What one controller should be doing now. A game sets a level and later stops it (or lets it run out).
    public struct State: Equatable, Sendable {
        public private(set) var strength = 0.0
        public private(set) var until = 0.0
        public init() {}
        /// Longest a request without an end (or with a very long one) runs before it needs renewing: a game that
        /// quits mid-rumble mustn't leave the controller buzzing.
        public static let longest = 5.0
        public mutating func apply(_ r: Request, now: Double) {
            strength = r.strength
            let seconds = r.milliseconds == 0 ? Self.longest : min(Self.longest, Double(r.milliseconds) / 1000)
            until = strength > 0 ? now + seconds : now
        }
        public func strength(at now: Double) -> Double { now < until ? strength : 0 }
    }

    public static func isOriginalSteamController(vendor: Int, product: Int) -> Bool {
        vendor == 0x28de && (product == 0x1102 || product == 0x1142)
    }
}
