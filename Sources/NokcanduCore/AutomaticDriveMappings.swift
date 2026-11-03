import Foundation

/// Track only drive letters newly created by managed Wine initialization while
/// macOS proves their target belongs to a disk image. Unknown mappings stay intact.
public enum AutomaticDriveMappings {
    private static let mutationLock = NSRecursiveLock()
    struct Mapping: Codable, Equatable {
        var letter: String
        var destination: String
        var rawDestination: String?
        func target(prefix: URL) -> String {
            destination.hasPrefix("/") ? destination : prefix.appendingPathComponent("dosdevices/" + destination).standardizedFileURL.path
        }
    }
    struct Record: Codable, Equatable {
        enum Origin: String, Codable { case wineInitialization, userRemoval }
        var mapping: Mapping
        var origin: Origin
        var imagePath: String?
    }
    static func state(_ contents: URL, _ name: String) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/" + name + ".json") }
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard url.resolvingSymlinksInPath() == url else { return nil }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    static func save<T: Encodable>(_ value: T, at url: URL) throws {
        guard url.resolvingSymlinksInPath() == url else { throw NokError("The drive ownership record is linked; it was preserved.") }
        try NokPaths.ensure(url.deletingLastPathComponent())
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    static func snapshot(prefix: URL) -> [String: Mapping] {
        let directory = prefix.appendingPathComponent("dosdevices"), fm = FileManager.default
        var result: [String: Mapping] = [:]
        for letter in "DEFGHIJKLMNOPQRSTUVWXY".map(String.init) {
            let name = letter.lowercased()
            guard let target = try? fm.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(name + ":").path) else { continue }
            result[letter] = Mapping(letter: letter, destination: target,
                rawDestination: try? fm.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(name + "::").path))
        }
        return result
    }
    static func recordNew(contents: URL, before: [String: Mapping], images: [String: [String]]) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let prefix = contents.appendingPathComponent("SharedSupport/prefix")
        let file = state(contents, "automatic-media-drives")
        var records = read([String: Record].self, at: file) ?? [:]
        let manual = read([String: String].self, at: state(contents, "manual-drives")) ?? [:]
        for (letter, mapping) in snapshot(prefix: prefix) where before[letter] == nil && mapping.rawDestination != nil {
            let target = mapping.target(prefix: prefix)
            guard target.hasPrefix("/Volumes/"), manual[letter] != target,
                  let image = images.first(where: { $0.value.contains(where: { Discs.real($0) == Discs.real(target) }) }) else { continue }
            records[letter] = Record(mapping: mapping, origin: .wineInitialization, imagePath: image.key)
        }
        if !records.isEmpty { try save(records, at: file) }
    }
    static func rememberManual(_ letter: String, target: String?, contents: URL) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let file = state(contents, "manual-drives")
        var values = read([String: String].self, at: file) ?? [:]
        values[letter.uppercased()] = target
        try save(values, at: file)
    }
    static func references(_ letter: String, games: [InstalledGame], prefix: URL) -> Bool {
        // A configured game disc is deliberate even when it is unmounted.
        if letter == "D", games.contains(where: { $0.custom?.disc != nil || $0.recipe?.disc != nil }) { return true }
        let pattern = "(?i)(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: letter) + #":[\\/]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let launchers = games.flatMap { game -> [String] in
            let directory = game.contents.appendingPathComponent("MacOS")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            return files.compactMap { file in
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else { return nil }
                return try? String(contentsOf: file, encoding: .utf8)
            }
        }
        let values = games.flatMap { game -> [String] in
            var strings = [game.custom?.exe, game.custom?.arguments, game.hosted?.exe].compactMap { $0 }
            strings += Array(game.custom?.environment?.values ?? Dictionary<String, String>().values)
            return strings
        } + launchers + ["system.reg", "user.reg"].compactMap { try? String(contentsOf: prefix.appendingPathComponent($0), encoding: .utf8) }
        return values.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }
    /// Closed environments only. Delete links, never their volume/device targets.
    @discardableResult
    static func reconcileHost(contents: URL, games: [InstalledGame], closed: Bool) throws -> Int {
        guard closed else { return 0 }
        mutationLock.lock(); defer { mutationLock.unlock() }
        let prefix = contents.appendingPathComponent("SharedSupport/prefix")
        let file = state(contents, "automatic-media-drives")
        guard var records = read([String: Record].self, at: file), !records.isEmpty else { return 0 }
        let manual = read([String: String].self, at: state(contents, "manual-drives")) ?? [:]
        let undoFile = state(contents, "removed-media-drives")
        var undo = read([Record].self, at: undoFile) ?? [], removed = 0
        for (letter, record) in records {
            guard "DEFGHIJKLMNOPQRSTUVWXY".map(String.init).contains(letter), record.mapping.letter == letter,
                  snapshot(prefix: prefix)[letter] == record.mapping else { continue }
            let target = record.mapping.target(prefix: prefix)
            guard target.hasPrefix("/Volumes/"), LauncherInstallation.presence(at: URL(fileURLWithPath: target)) == .offline,
                  manual[letter] != target, !references(letter, games: games, prefix: prefix) else { continue }
            if !undo.contains(record) { undo.append(record) }
            try save(undo, at: undoFile) // durable recovery before either unlink
            guard try unlink(record.mapping, prefix: prefix) else { continue }
            records[letter] = nil; removed += 1
        }
        try save(records, at: file)
        return removed
    }
    @discardableResult
    static func unlink(_ mapping: Mapping, prefix: URL) throws -> Bool {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard snapshot(prefix: prefix)[mapping.letter] == mapping else { return false }
        let fm = FileManager.default, directory = prefix.appendingPathComponent("dosdevices")
        let name = mapping.letter.lowercased(), link = directory.appendingPathComponent(mapping.letter.lowercased() + ":")
        let raw = directory.appendingPathComponent(name + "::")
        do {
            if mapping.rawDestination != nil { try fm.removeItem(at: raw) }
            try fm.removeItem(at: link)
        } catch {
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil, !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: mapping.destination)
            }
            if let destination = mapping.rawDestination,
               (try? fm.destinationOfSymbolicLink(atPath: raw.path)) == nil, !fm.fileExists(atPath: raw.path) {
                try? fm.createSymbolicLink(atPath: raw.path, withDestinationPath: destination)
            }
            throw error
        }
        return true
    }
    @discardableResult
    public static func reconcile(games: [InstalledGame]) -> Int {
        let hosts = Dictionary(grouping: games.compactMap { game in WineTools.hostContents(for: game).map { ($0, game) } }, by: { $0.0 }).filter { contents, _ in
            !(read([String: Record].self, at: state(contents, "automatic-media-drives")) ?? [:]).isEmpty
        }
        guard !hosts.isEmpty else { return 0 }
        let processes = GameLauncher.processStatus()
        guard processes.reliable else { return 0 }
        return hosts.reduce(0) { count, pair in
            let (contents, peers) = pair
            let closed = !processes.rows.contains { WineTools.owns(pid: $0.0, contents: contents) }
            return count + ((try? reconcileHost(contents: contents, games: peers.map(\.1), closed: closed)) ?? 0)
        }
    }
    public static func hasUndo(for game: InstalledGame) -> Bool {
        guard let contents = WineTools.hostContents(for: game) else { return false }
        return !(read([Record].self, at: state(contents, "removed-media-drives")) ?? []).isEmpty
    }
    public static func undo(for game: InstalledGame) throws {
        guard let contents = WineTools.hostContents(for: game) else { return }
        let processes = GameLauncher.processStatus()
        guard processes.reliable, !processes.rows.contains(where: { WineTools.owns(pid: $0.0, contents: contents) }) else { throw NokError("Close this game's Windows environment before restoring drive mappings.") }
        mutationLock.lock(); defer { mutationLock.unlock() }
        let file = state(contents, "removed-media-drives"), prefix = contents.appendingPathComponent("SharedSupport/prefix")
        let records = read([Record].self, at: file) ?? []
        var remaining: [Record] = []
        for record in records {
            let mapping = record.mapping, name = mapping.letter.lowercased()
            guard "DEFGHIJKLMNOPQRSTUVWXY".map(String.init).contains(mapping.letter) else { continue }
            let link = prefix.appendingPathComponent("dosdevices/" + name + ":"), raw = prefix.appendingPathComponent("dosdevices/" + name + "::")
            guard (try? FileManager.default.attributesOfItem(atPath: link.path)) == nil,
                  (try? FileManager.default.attributesOfItem(atPath: raw.path)) == nil else { remaining.append(record); continue }
            try rememberManual(mapping.letter, target: mapping.target(prefix: prefix), contents: contents)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: mapping.destination)
            do {
                if let destination = mapping.rawDestination { try FileManager.default.createSymbolicLink(atPath: raw.path, withDestinationPath: destination) }
            } catch {
                // Preserve the recovery record and avoid a half-restored pair.
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == mapping.destination { try? FileManager.default.removeItem(at: link) }
                throw error
            }
        }
        try save(remaining, at: file)
    }
}
