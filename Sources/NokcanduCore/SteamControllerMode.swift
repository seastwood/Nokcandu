import Foundation

/// Original 2015 controller volatile settings, per Valve's SDL protocol.
/// Deliberately excludes settings reset, pairing and firmware commands.
public enum SteamControllerMode {
    /// The controller's built-in button actions (trigger = mouse click, A = Return, …) are "digital mappings",
    /// separate from the settings below: pads off and lizard mode off leave them active, so an unmapped
    /// trigger still clicked the real Mac pointer. Clearing them is volatile, as in Valve's SDL driver; the
    /// second command puts the controller's own defaults back when Nokcandu releases it.
    public static var clearDigitalMappings: [UInt8] { command(0x81) }
    public static var defaultDigitalMappings: [UInt8] { command(0x85) }
    private static func command(_ id: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64); bytes[0] = id; return bytes
    }
    public static let tags: [UInt8] = [7, 8, 9, 48, 49]
    public typealias Settings = [UInt8: UInt16]
    public static var query: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x89; bytes[1] = UInt8(tags.count * 3)
        for (index, tag) in tags.enumerated() { bytes[2 + index * 3] = tag }
        return bytes
    }
    public static func decode(_ bytes: [UInt8]) -> Settings? {
        guard bytes.count >= 2, bytes[0] == 0x89 else { return nil }
        let count = Int(bytes[1])
        guard count == tags.count * 3, count + 2 <= bytes.count else { return nil }
        var result: Settings = [:]
        for i in stride(from: 2, to: count + 2, by: 3) {
            guard tags.contains(bytes[i]), result[bytes[i]] == nil else { return nil }
            result[bytes[i]] = UInt16(bytes[i + 1]) | UInt16(bytes[i + 2]) << 8
        }
        return result
    }
    public static func write(_ values: Settings) -> [UInt8]? {
        guard Set(values.keys) == Set(tags) else { return nil }
        var bytes = query; bytes[0] = 0x87
        for (index, tag) in tags.enumerated() {
            let value = values[tag]!
            bytes[3 + index * 3] = UInt8(value & 255)
            bytes[4 + index * 3] = UInt8(value >> 8)
        }
        return bytes
    }
    public static func captured(_ original: Settings) -> Settings? {
        guard Set(original.keys) == Set(tags) else { return nil }
        var result = original
        result[7] = 7; result[8] = 7 // TRACKPAD_NONE
        result[9] = 0 // LIZARD_MODE_OFF: no firmware desktop keyboard/mouse
        result[48] = original[48]! | 0x18 // raw accelerometer and gyro; retain other IMU bits
        return result
    }
    public struct Lease: Codable, Equatable {
        public var device: UInt64
        public var original: Settings
        public var applied: Settings
        public init?(device: UInt64, original: Settings) {
            guard device != 0, let applied = SteamControllerMode.captured(original) else { return nil }
            self.device = device; self.original = original; self.applied = applied
        }
        /// Do not overwrite settings changed by another owner (for example Steam).
        public func canRestore(device currentDevice: UInt64, current: Settings) -> Bool {
            currentDevice == device && current == applied
        }
    }
}
