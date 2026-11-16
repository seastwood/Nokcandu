import Foundation

/// Nintendo's GameCube controller adapter for Wii U and Switch (057E:0337, in its Wii U mode), and its clones:
/// four controller ports in one device. It starts sending once it gets output report 0x13; each report (0x21)
/// then has nine bytes per port. Layout from SDL's driver (SDL_hidapi_gamecube.c).
public enum GameCubeAdapter {
    public static let vendor = 0x057E, product = 0x0337
    public static let start: [UInt8] = [0x13]

    /// Each port's controller, or nil when nothing is plugged into it. Axes in SDL's order (y down, triggers
    /// 0…32767); the triggers' clicks at the end of their travel are full pulls.
    public static func decode(_ d: [UInt8]) -> [(buttons: Set<PadProfiles.Input>, axes: [Int: Int])?]? {
        guard d.count >= 37, d[0] == 0x21 else { return nil }
        return (0..<4).map { port -> (buttons: Set<PadProfiles.Input>, axes: [Int: Int])? in
            let s = Array(d[(1 + port * 9)..<(10 + port * 9)])
            guard s[0] & 0x30 != 0 else { return nil }
            var held = Set<PadProfiles.Input>()
            let bits: [(Int, UInt8, PadProfiles.Input)] = [
                (1, 0x01, .a), (1, 0x02, .b), (1, 0x04, .x), (1, 0x08, .y),
                (1, 0x10, .left), (1, 0x20, .right), (1, 0x40, .down), (1, 0x80, .up),
                (2, 0x01, .start), (2, 0x02, .rb),
            ]
            for (i, b, input) in bits where s[i] & b != 0 { held.insert(input) }
            // Sticks rest at 128 and reach about ±88; up is higher.
            func stick(_ v: UInt8, invert: Bool) -> Int {
                let x = max(-1, min(1, (Double(v) - 128) / 88))
                return Int((invert ? -x : x) * 32767)
            }
            func trigger(_ v: UInt8, click: Bool) -> Int { click ? 32767 : Int(max(0, min(1, (Double(v) - 40) / 180)) * 32767) }
            let axes = [0: stick(s[3], invert: false), 1: stick(s[4], invert: true),
                        2: stick(s[5], invert: false), 3: stick(s[6], invert: true),
                        4: trigger(s[7], click: s[2] & 0x08 != 0), 5: trigger(s[8], click: s[2] & 0x04 != 0)]
            return (held, axes)
        }
    }
}
