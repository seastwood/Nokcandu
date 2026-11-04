import Foundation

/// Game-specific settings; leaves shared Wine audio and microphone policy unchanged.
public enum BF1942AudioFix {
    static let key = "game.sethardware"
    static func file(_ g: InstalledGame) -> URL? {
        guard let folder = BF1942DisplayFix.folder(g) else { return nil }
        let settings = folder.appendingPathComponent("Mods/bf1942/Settings")
        let root = settings.resolvingSymlinksInPath().path + "/"
        let routing = settings.appendingPathComponent("Sound.con")
        guard settings.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              routing.resolvingSymlinksInPath().path.hasPrefix(root),
              let size = try? routing.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256_000,
              let text = try? TextSettings.read(routing) else { return nil }
        let routes = TextSettings.lines(text).compactMap { line -> String? in
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard words.count == 2, words[0].lowercased() == "run" else { return nil }
            return String(words[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        }
        guard routes.count == 1 else { return nil }
        let parts = routes[0].split(separator: "/")
        guard parts.count == 3, parts[0].lowercased() == "profiles", parts[1] != ".", parts[1] != "..",
              parts[2].lowercased() == "sound.con" else { return nil }
        let file = settings.appendingPathComponent(routes[0])
        guard file.resolvingSymlinksInPath().path.hasPrefix(root),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) < 256_000,
              let sound = try? TextSettings.read(file), ["0", "1"].contains(value(sound) ?? "") else { return nil }
        return file
    }
    static func value(_ text: String) -> String? {
        TextSettings.lines(text).filter { TextSettings.key($0) == key }.last?
            .split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init)
    }
    public static func supports(_ g: InstalledGame) -> Bool { file(g) != nil }
    public static func isConfigured(_ g: InstalledGame) -> Bool {
        guard let file = file(g), let text = try? TextSettings.read(file) else { return false }
        return value(text) == "0"
    }
    static func plannedFiles(_ g: InstalledGame) throws -> [URL: Data] {
        guard let file = file(g) else { throw NokError("BF1942's active player sound settings could not be identified safely.") }
        let bytes = try Data(contentsOf: file), text = try TextSettings.decode(bytes)
        let changed = TextSettings.merge(current: text, valuesFrom: "game.setHardware 0\n", keys: [key])
        return [file: try TextSettings.encode(changed, like: bytes)]
    }
}
