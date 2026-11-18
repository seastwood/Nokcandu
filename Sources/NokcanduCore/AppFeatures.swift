import Foundation

/// Built-in features share data and ship together. Visibility never owns or deletes their data.
public enum AppFeature: String, CaseIterable, Identifiable, Codable {
    case games, profiles, streams
    public var id: String { rawValue }
    public var title: String {
        switch self { case .games: return "Games"; case .profiles: return "Remapping"; case .streams: return "Streaming" }
    }
    public var symbol: String {
        switch self { case .games: return "square.stack.3d.up"; case .profiles: return "gamecontroller"; case .streams: return "tv" }
    }
    public var detail: String {
        switch self {
        case .games: return "Install and manage Windows and Mac games, stores and Wine engines."
        case .profiles: return "Create controller, gyro and keyboard profiles for apps, games and streams."
        case .streams: return "Play remotely from a PC running Sunshine, Apollo or GameStream."
        }
    }
}

public struct AppFeatures: Equatable {
    public static let defaultsKey = "enabledFeatures.v1"
    public var enabled: Set<AppFeature>
    public init(enabled: Set<AppFeature> = Set(AppFeature.allCases)) { self.enabled = enabled }
    public init(defaults: UserDefaults) {
        // An absent preference preserves every existing installation. An empty array means all hidden.
        if let values = defaults.stringArray(forKey: Self.defaultsKey) {
            enabled = Set(values.compactMap(AppFeature.init(rawValue:)))
        } else { enabled = Set(AppFeature.allCases) }
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
