import Foundation

/// Built-in, configuration-only recipe. Community profiles can reference its ID, never edit paths.
public enum OpenUASettings {
    static let modes = ["640x480", "800x600", "1024x768", "1280x800"]
    static func ini(_ g: InstalledGame) -> URL? {
        guard g.custom != nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil, g.native == nil,
              let exe = CompatibilityFixes.managedProgram(g), exe.lastPathComponent.lowercased() == "ua_source.exe",
              PEFile.inspect(exe)?.imports.contains(where: { $0.lowercased() == "opengl32.dll" }) == true else { return nil }
        let folder = exe.deletingLastPathComponent(), real = folder.resolvingSymlinksInPath().path
        let ini = folder.appendingPathComponent("NUCLEUS.INI")
        guard ini.resolvingSymlinksInPath().path.hasPrefix(real + "/"),
              FileManager.default.fileExists(atPath: ini.path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("DATA/world.ini").path),
              FileManager.default.isDirectory(folder.appendingPathComponent("LEVELS")) else { return nil }
        return ini
    }
    public static func supports(_ g: InstalledGame) -> Bool { ini(g) != nil }
    static func value(_ key: String, in text: String) -> String? {
        text.components(separatedBy: .newlines).compactMap { line -> String? in
            let uncommented = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let pair = uncommented.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == key else { return nil }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }.last
    }
    static func configuredText(_ original: String) -> String {
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        var lines = original.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var existing = (value("gfx.custommodes", in: original) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for mode in modes where !existing.contains(where: { $0.lowercased() == mode }) { existing.append(mode) }
        let edits = ["gfx.vbo": "off", "menu.windowed": "off", "gfx.custommodes": existing.joined(separator: ",")]
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            var found = false
            for i in lines.indices {
                let pair = lines[i].split(separator: "=", maxSplits: 1)
                if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == key {
                    let comment = lines[i].firstIndex(of: ";").map { " " + lines[i][$0...] } ?? ""
                    lines[i] = key + " = " + value + comment; found = true
                }
            }
            if !found { lines.append(key + " = " + value) }
        }
        return lines.joined(separator: newline)
    }
    static func plannedFiles(for g: InstalledGame) throws -> [URL: Data] {
        guard let path = ini(g) else { throw NokError("Choose OpenUA’s UA_source.exe first. Its game data must be in the same folder.") }
        let data = try Data(contentsOf: path)
        guard data.count <= 256_000, let text = String(data: data, encoding: .isoLatin1),
              let changed = configuredText(text).data(using: .isoLatin1) else { throw NokError("OpenUA’s settings file has an unfamiliar format. It was left unchanged.") }
        return [path: changed]
    }
    public static func isConfigured(_ g: InstalledGame) -> Bool {
        guard let path = ini(g), let text = try? String(contentsOf: path, encoding: .isoLatin1),
              value("gfx.vbo", in: text)?.lowercased() == "off", value("menu.windowed", in: text)?.lowercased() == "off" else { return false }
        let present = (value("gfx.custommodes", in: text) ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return modes.allSatisfy { present.contains($0) }
    }
}
