import Foundation

/// Cosmetic changes only: never selects a launch program or regenerates a launcher.
public enum GameIcon {
    public static func supports(_ g: InstalledGame) -> Bool { g.native == nil }
    static func journal(_ g: InstalledGame) -> ChangeJournal {
        ChangeJournal(scope: "game-icon", root: g.nokcanduState, portableRoot: g.appURL)
    }
    public static func hasChanges(_ g: InstalledGame) -> Bool { journal(g).hasChanges }

    public static func set(from executable: URL, for g: InstalledGame) throws {
        guard supports(g) else { throw NokError("This icon editor is for Nokcandu's Windows game apps.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("nok-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent("chosen.icns")
        guard PEFile.writeIcns(from: executable, to: staged, workDir: work) else {
            throw NokError("This program doesn't contain an icon Nokcandu can use. Choose another EXE.")
        }
        try apply(try Data(contentsOf: staged), for: g)
    }

    static func apply(_ icon: Data, for g: InstalledGame) throws {
        guard supports(g), icon.starts(with: Data("icns".utf8)) else { throw NokError("The icon isn't a valid Mac icon.") }
        let plist = g.contents.appendingPathComponent("Info.plist")
        let resources = g.contents.appendingPathComponent("Resources")
        guard plist.resolvingSymlinksInPath() == plist.standardizedFileURL,
              resources.resolvingSymlinksInPath() == resources.standardizedFileURL,
              var info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw NokError("The app's icon files are missing or linked elsewhere. They were left untouched.")
        }
        // Reuse the existing icon path, so normal updates and generated game identities
        // keep the user's artwork. Reject paths escaping the app's resources.
        var name = info["CFBundleIconFile"] as? String ?? "NokcanduIcon.icns"
        if !name.hasSuffix(".icns") { name += ".icns" }
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { throw NokError("The app's icon path isn't supported.") }
        let target = resources.appendingPathComponent(name)
        guard target.resolvingSymlinksInPath() == target.standardizedFileURL else { throw NokError("The icon is linked elsewhere. It was left untouched.") }
        let ledger = journal(g)
        try ledger.validateForUndo()
        try ledger.write(icon, to: target, reason: "User-selected game icon")
        if info["CFBundleIconFile"] as? String == nil {
            info["CFBundleIconFile"] = name
            try ledger.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                             to: plist, reason: "Game icon reference")
        }
        _ = try? Shell.run("/usr/bin/touch", [g.appURL.path])
    }

    public static func undo(_ g: InstalledGame) throws {
        let ledger = journal(g)
        try ledger.validateForUndo()
        let result = ledger.revertAll()
        guard result.skipped.isEmpty else { throw NokError(result.summary) }
        _ = try? Shell.run("/usr/bin/touch", [g.appURL.path])
    }
}
