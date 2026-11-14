// SPDX-License-Identifier: GPL-3.0-only
// One plain sentence for a game's Controls tab: what the game gets from the controllers, after every setting that
// decides it (the environment's route, the profile's emulated controller, a profile used everywhere, profiles off).
import Foundation

public enum ControllerSummary {
    public struct Profile: Equatable, Sendable {
        public var name: String
        public var presentAs: PresentedController?
        public var gyro: PadProfiles.GyroOutput
        /// The gyro starts off and a button turns it on.
        public var gyroByButton: Bool
        public var changed: Int
        public init(name: String, presentAs: PresentedController? = nil, gyro: PadProfiles.GyroOutput = .off, gyroByButton: Bool = false, changed: Int = 0) {
            self.name = name; self.presentAs = presentAs; self.gyro = gyro; self.gyroByButton = gyroByButton; self.changed = changed
        }
        public init(_ p: PadProfiles.Profile, all: [PadProfiles.Profile]) {
            let m = PadProfiles.merged(p, all: all)
            let turnsOn = m.layers.contains { $0.bindings.values.contains { b in
                (b.press + b.tap + b.hold + b.double).contains { $0 == .gyroOn || $0 == .gyroToggle } } }
            self.init(name: p.name, presentAs: PadProfiles.top(p, all: all, \.presentAs), gyro: m.gyro.output,
                      gyroByButton: !m.gyro.startsOn && turnsOn, changed: m.layers.first?.bindings.count ?? 0)
        }
    }

    /// What the game's controllers are presented as.
    public static func seenAs(mode: Controllers.Mode, steam: Bool, profile: Profile?) -> String {
        if mode == .hidden { return "no controller (keys and mouse only)" }
        if let p = profile?.presentAs { return p.title }
        switch profile != nil && mode == .automatic ? .xbox : mode {
        case .xbox: return "Xbox controller"
        case .native: return steam ? "itself, for Steam Input" : "itself"
        case .hidden: return "no controller"
        case .automatic: return steam ? "itself, for Steam Input" : "Wine's choice (an Xbox controller for most)"
        }
    }

    /// "Steam Controller → Xbox controller · profile “X” (used everywhere) · gyro as the right stick (a button turns it
    /// on) · rumble on the trackpads"
    public static func line(controllers: [String], steamController: Bool, mode: Mode, steam: Bool, profile: Profile?,
                            everywhere: Bool, profilesOff: Bool) -> String {
        let p = profilesOff ? nil : profile
        var parts: [String] = []
        let who = controllers.isEmpty ? "No controller connected — games will see" : controllers.joined(separator: ", ") + " →"
        parts.append("\(who) \(seenAs(mode: mode, steam: steam, profile: p))")
        if profilesOff { parts.append("controller profiles are off") }
        else if let p {
            parts.append("profile “\(p.name)”" + (everywhere ? " (used everywhere)" : ""))
            if p.gyro != .off { parts.append("gyro as the \(p.gyro.title.lowercased())" + (p.gyroByButton ? " (a button turns it on)" : "")) }
        } else { parts.append("no profile: buttons do what the game says") }
        if steamController && mode != .hidden { parts.append("rumble on the trackpads") }
        return parts.joined(separator: " · ")
    }
    public typealias Mode = Controllers.Mode
}
