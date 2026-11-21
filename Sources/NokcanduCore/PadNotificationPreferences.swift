import Foundation

public enum PadNotificationPreferences {
    public static let gyroKey = "padGyroSwitchNotifications"
    public static func gyroSwitches(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: gyroKey) as? Bool ?? true
    }
    public static func setGyroSwitches(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: gyroKey)
    }
    public static func shouldShowGyro(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: "padHUDOff") && gyroSwitches(defaults)
    }

    /// Nokcandu's notes and notifications wait while a game or stream is in front (on unless turned off): anything
    /// appearing over a full-screen game or stream makes macOS compose the screen again, which adds delay.
    public static let holdKey = "holdNotificationsWhilePlaying"
    public static func holdWhilePlaying(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: holdKey) as? Bool ?? true
    }
    public static func setHoldWhilePlaying(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: holdKey)
    }
}

/// Notifications held while playing, shown when you stop: the latest few, without repeats.
public struct HeldNotifications<Note: Equatable> {
    public private(set) var notes: [Note] = []
    public let limit: Int
    public init(limit: Int = 5) { self.limit = limit }
    public mutating func hold(_ note: Note) {
        notes.removeAll { $0 == note }
        notes.append(note)
        if notes.count > limit { notes.removeFirst(notes.count - limit) }
    }
    public mutating func release() -> [Note] { defer { notes = [] }; return notes }
}
