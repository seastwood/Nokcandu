import Foundation

/// Built-in features share data and ship together. Visibility never owns or deletes their data.
public enum AppFeature: String, CaseIterable, Identifiable, Codable {
    /// In the order of the tabs: Nokcandu is a controller remapper first, a streaming client second, and a games
    /// installer and launcher third.
    case profiles, streams, games
    public var id: String { rawValue }
    public var title: String {
        switch self { case .games: return "Games"; case .profiles: return "Remapping"; case .streams: return "Streaming" }
    }
    public var symbol: String {
        switch self { case .games: return "square.stack.3d.up"; case .profiles: return "gamecontroller"; case .streams: return "moon.fill" }
    }
    public var detail: String {
        switch self {
        case .games: return "Install and manage Windows and Mac games, stores and Wine engines. For the best experience running Windows games, CodeWeavers' CrossOver is recommended."
        case .profiles: return "Create controller, gyro and keyboard profiles for apps, games and streams."
        case .streams: return "Play remotely from a PC running Sunshine, Apollo or GameStream."
        }
    }
}

extension AppFeature {
    /// Remapping and Streaming are stable; Games (Windows games through Wine) is experimental.
    public var isExperimental: Bool { self == .games }
    public var stability: String { isExperimental ? "Experimental" : "Stable" }
}

public struct AppFeatures: Equatable {
    /// A fresh installation starts with the stable features; Games is turned on in Settings.
    public static let freshInstall: Set<AppFeature> = [.profiles, .streams]
    public static let defaultsKey = "enabledFeatures.v1"
    public var enabled: Set<AppFeature>
    public init(enabled: Set<AppFeature> = Set(AppFeature.allCases)) { self.enabled = enabled }
    public init(defaults: UserDefaults) {
        // An absent preference preserves every existing installation (one that finished the welcome); a fresh one
        // starts with the stable features. An empty array means all hidden.
        if let values = defaults.stringArray(forKey: Self.defaultsKey) {
            enabled = Set(values.compactMap(AppFeature.init(rawValue:)))
        } else { enabled = defaults.bool(forKey: "welcomeDone") ? Set(AppFeature.allCases) : Self.freshInstall }
    }
    public func contains(_ feature: AppFeature) -> Bool { enabled.contains(feature) }
    public var visible: [AppFeature] { AppFeature.allCases.filter(contains) }
    public func selection(_ requested: AppFeature) -> AppFeature? { contains(requested) ? requested : visible.first }
    /// Hiding the editor doesn't change a profile already assigned to a game or an ongoing stream.
    public func allowsProfile(forGame: Bool, inStream: Bool) -> Bool { contains(.profiles) || forGame || inStream }
    public func ownsControllersInBackground(exclusivePreference: Bool) -> Bool { contains(.profiles) && exclusivePreference }
    public func save(to defaults: UserDefaults) { defaults.set(visible.map(\.rawValue), forKey: Self.defaultsKey) }
    public static var current: Self { Self(defaults: .standard) }
}
