import Foundation

/// Ignoring a version only dismisses its notification; installation remains available in Updates.
public struct UpdateNotice: Hashable, Codable {
    public enum Kind: String, Codable { case app, engine, cinematic, store }
    public var kind: Kind
    public var target: String
    public var version: String
    public init(kind: Kind, target: String = "", version: String) {
        self.kind = kind; self.target = target; self.version = version
    }
}

public struct UpdateNoticePreferences: Equatable {
    public static let defaultsKey = "ignoredUpdateNotices.v1"
    public private(set) var ignored: Set<UpdateNotice>
    public init(ignored: Set<UpdateNotice> = []) { self.ignored = ignored }
    public init(defaults: UserDefaults) {
        ignored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Set<UpdateNotice>.self, from: $0) } ?? []
    }
    public func contains(_ notice: UpdateNotice) -> Bool { ignored.contains(notice) }
    public mutating func setIgnored(_ notice: UpdateNotice, _ value: Bool) {
        if value { ignored.insert(notice) } else { ignored.remove(notice) }
    }
    public mutating func reset() { ignored.removeAll() }
    public func save(to defaults: UserDefaults) { defaults.set(try? JSONEncoder().encode(ignored), forKey: Self.defaultsKey) }
}

public struct UpdateNoticeSummary: Equatable {
    public enum Badge { case none, app, components }
    public let appCount: Int
    public let componentCount: Int
    public var count: Int { appCount + componentCount }
    public var badge: Badge { appCount > 0 ? .app : componentCount > 0 ? .components : .none }
    public init(notices: [UpdateNotice], features: AppFeatures, preferences: UpdateNoticePreferences) {
        let visible = Set(notices).filter { !preferences.contains($0) && ($0.kind == .app || features.contains(.games)) }
        appCount = visible.filter { $0.kind == .app }.count
        componentCount = visible.count - appCount
    }
}

/// Keep a successful app check across launches, independently of the Wine catalog's age.
public enum AppUpdateAvailability {
    public static let defaultsKey = "availableAppUpdate.v1"
    public static func load(defaults: UserDefaults, currentVersion: String) -> AppUpdate.Release? {
        guard let data = defaults.data(forKey: defaultsKey),
              let release = try? JSONDecoder().decode(AppUpdate.Release.self, from: data),
              AppUpdate.isNewer(release.version, than: currentVersion) else { return nil }
        return release
    }
    public static func save(_ release: AppUpdate.Release?, defaults: UserDefaults) {
        if let release { defaults.set(try? JSONEncoder().encode(release), forKey: defaultsKey) }
        else { defaults.removeObject(forKey: defaultsKey) }
    }
}

extension UpdateNotice {
    public static func app(_ release: AppUpdate.Release) -> Self { .init(kind: .app, version: release.version) }
    public static func engine(_ game: InstalledGame, engine: EngineVersion, template: TemplateVersion) -> Self {
        .init(kind: .engine, target: game.id, version: RuntimeManager.runtimeID(engine: engine, template: template))
    }
    public static func cinematic(_ game: InstalledGame, version: String) -> Self { .init(kind: .cinematic, target: game.id, version: version) }

    /// Filesystem inspection runs off the main thread. Held engines aren't update notifications.
    public static func available(games: [InstalledGame], catalog: UpdateCatalog?, app: AppUpdate.Release?, includeGames: Bool, storeUpdates: [String: StoreUpdates.Available] = [:], failedEngine: (String) -> Bool = EngineSelfTests.failed) -> [Self] {
        var result = app.map { [Self.app($0)] } ?? []
        guard includeGames else { return result }
        for (id, update) in storeUpdates {
            result.append(.init(kind: .store, target: id, version: update.latest))
        }
        guard let catalog else { return result }
        let hosts = EngineUpdate.hosts(in: games)
        if let newest = catalog.latestEngine?.version {
            let template = catalog.latestTemplate?.version ?? .tested
            if !failedEngine(RuntimeManager.runtimeID(engine: newest, template: template)) {
                for game in hosts where !EngineUpdate.isHeld(game) && EngineUpdate.state(for: game)?.status != .trying {
                    if EngineUpdate.current(game).map({ $0 < newest }) == true {
                        result.append(.engine(game, engine: newest, template: template))
                    }
                }
            }
        }
        if let lav = catalog.lav {
            for game in hosts where CinematicFix.state(for: game).map({ $0.version != lav.version }) == true {
                result.append(.cinematic(game, version: lav.version))
            }
        }
        return result
    }
}
