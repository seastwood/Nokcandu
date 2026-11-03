import Foundation

/// Session-only estimates. Opening Storage never starts every expensive disk walk.
public actor StorageInventory {
    public static let shared = StorageInventory()
    public enum Section: String, CaseIterable, Identifiable { case drives, games, appData, leftovers
        public var id: String { rawValue }
        public var title: String {
            switch self { case .drives: "Drives & folders"; case .games: "Games"; case .appData: "Nokcandu data"; case .leftovers: "Leftovers" }
        }
    }
    public struct Snapshot {
        public var items: [Storage.Item] = []
        public var leftovers: [GameRemoval.Item] = []
        public var volumes: [Storage.VolumeInfo] = []
        public var measuredAt: Date = Date()
    }
    struct Key: Hashable { var section: Section; var library: [InstalledGame] }
    struct Flight { var id: UUID; var generation: Int; var task: Task<Snapshot, Never> }
    private var results: [Key: Snapshot] = [:]
    private var flights: [Key: Flight] = [:]
    private var latest: [Section: UUID] = [:]
    private var generation = 0
    private let lifetime: TimeInterval
    public init(lifetime: TimeInterval = 300) { self.lifetime = lifetime }
    public func invalidate() { generation += 1; results.removeAll() }
    public func load(_ section: Section, library: [InstalledGame]) async -> Snapshot {
        let key = Key(section: section, library: (section == .appData || section == .drives) ? [] : library)
        return await value(for: key) {
            switch section {
            case .games: return Snapshot(items: Storage.games(library))
            case .appData: return Snapshot(items: Storage.nokcanduData())
            case .leftovers: return Snapshot(leftovers: GameRemoval.orphans(library: library))
            case .drives: return Snapshot(volumes: Storage.volumes())
            }
        }
    }
    func value(for key: Key, loader: @escaping @Sendable () async -> Snapshot) async -> Snapshot {
        if let result = results[key], Date().timeIntervalSince(result.measuredAt) < (key.section == .drives ? min(lifetime, 15) : lifetime) { return result }
        if let flight = flights[key] {
            let result = await flight.task.value
            if flight.generation == generation { return result }
            // A cleanup/refresh invalidated this walk. Finish it before starting
            // a fresh walk, so rapid tab changes cannot pile up disk scans.
            if flights[key]?.id == flight.id { flights[key] = nil }
            return await value(for: key, loader: loader)
        }
        if let other = flights.first(where: { $0.key.section == key.section }) {
            _ = await other.value.task.value
            if flights[other.key]?.id == other.value.id { flights[other.key] = nil }
            return await value(for: key, loader: loader)
        }
        let started = generation, id = UUID()
        latest[key.section] = id
        let task = Task.detached(priority: .utility) {
            var result = await loader(); result.measuredAt = Date(); return result
        }
        flights[key] = Flight(id: id, generation: started, task: task)
        let result = await task.value
        if flights[key]?.id == id { flights[key] = nil }
        if generation == started, latest[key.section] == id {
            results = results.filter { $0.key.section != key.section }
            results[key] = result
        }
        return result
    }
}
