// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A DualSense adaptive-trigger effect from the host (`ConnListenerSetAdaptiveTriggers`), decoded from the
/// controller's raw effect bytes into what Apple's GameController framework can set
/// (`GCDualSenseAdaptiveTrigger`). Moonlight PC (6.2.0) writes the raw bytes to the controller through SDL;
/// GameController doesn't take raw bytes, so the effects it has a mode for are translated:
///
/// - 0x05 off; 0x21 feedback (10 zones, strength 1–8 each); 0x25 weapon (start and end zone, strength 1–8);
///   0x26 vibration (10 zones, amplitude 1–8 each, frequency in Hz); 0x22 bow is shown as weapon (its snap-back
///   force has no equivalent).
/// - The older "simple" effects: 0x01 feedback (start, strength), 0x02 weapon (start, end, strength),
///   0x06 vibration (frequency, amplitude, start), each 0–255.
///
/// Anything else (galloping, machine, calibration) leaves the trigger as it is, rather than guessing.
public enum StreamAdaptiveTrigger: Equatable {
    case off
    /// Resistance per zone (10 zones from released to fully pressed), 0…1; 0 means none in that zone.
    case feedback([Float])
    case feedbackFrom(start: Float, strength: Float)
    case weapon(start: Float, end: Float, strength: Float)
    /// Vibration amplitude per zone, 0…1, and frequency 0…1 (of the controller's range).
    case vibration([Float], frequency: Float)
    case vibrationFrom(start: Float, amplitude: Float, frequency: Float)

    public static let payloadSize = 10
    public static let zones = 10

    /// Nil for an effect with no GameController equivalent (leave the trigger alone).
    public static func decode(type: UInt8, payload p: [UInt8]) -> StreamAdaptiveTrigger? {
        guard p.count >= payloadSize else { return nil }
        func u16(_ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16 | Int(p[i + 3]) << 24 }
        /// Ten 3-bit values (stored as value − 1) for the active zones.
        func zoned(_ active: Int, _ packed: Int) -> [Float] {
            (0..<zones).map { z in active & (1 << z) == 0 ? 0 : Float(((packed >> (3 * z)) & 7) + 1) / 8 }
        }
        /// The two zones marked in a start/stop bit field.
        func startEnd(_ bits: Int) -> (Int, Int)? {
            let set = (0..<zones).filter { bits & (1 << $0) != 0 }
            guard let first = set.first, let last = set.last, last > first else { return nil }
            return (first, last)
        }
        let last = Float(zones - 1)
        switch type {
        case 0x00, 0x05:
            return .off
        case 0x21:
            let s = zoned(u16(0), u32(2))
            return s.allSatisfy { $0 == 0 } ? .off : .feedback(s)
        case 0x22, 0x25:
            guard let (a, b) = startEnd(u16(0)) else { return .off }
            return .weapon(start: Float(a) / last, end: Float(b) / last, strength: Float((Int(p[2]) & 7) + 1) / 8)
        case 0x26:
            let a = zoned(u16(0), u32(2))
            guard p[8] != 0, a.contains(where: { $0 > 0 }) else { return .off }
            return .vibration(a, frequency: Float(p[8]) / 255)
        case 0x01:
            return p[1] == 0 ? .off : .feedbackFrom(start: Float(p[0]) / 255, strength: Float(p[1]) / 255)
        case 0x02:
            guard p[2] != 0, p[1] > p[0] else { return .off }
            return .weapon(start: Float(p[0]) / 255, end: Float(p[1]) / 255, strength: Float(p[2]) / 255)
        case 0x06:
            guard p[0] != 0, p[1] != 0 else { return .off }
            return .vibrationFrom(start: Float(p[2]) / 255, amplitude: Float(p[1]) / 255, frequency: Float(p[0]) / 255)
        default:
            return nil
        }
    }
}
