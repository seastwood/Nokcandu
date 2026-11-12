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
}
