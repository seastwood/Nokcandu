import Foundation

/// Small compatibility binaries only. Never cache game executables, account logs,
/// settings or saves. Hashes and ownership come from the existing fix journals.
enum CompanionRepair {
    static func entries(_ game: InstalledGame) -> [(CompatibilityFix, JournalEntry)] {
        let roots = [game.contents.resolvingSymlinksInPath().path,
                     CompatibilityFixes.managedProgram(game)?.deletingLastPathComponent().resolvingSymlinksInPath().path].compactMap { $0 }
        var latest: [String: (CompatibilityFix, JournalEntry)] = [:]
        for fix in CompatibilityFix.allCases where fix != .ubisoftBrowser && fix != .openUA && CompatibilityFixes.isInstalled(fix, for: game) {
            for entry in CompatibilityFixes.journal(fix, game).entries where entry.settingsKeys == nil {
                let url = URL(fileURLWithPath: entry.path)
                guard ["dll", "exe", "so", "dylib"].contains(url.pathExtension) || url.lastPathComponent == NativeIPXNetworking.helperName else { continue }
                guard roots.contains(where: { url.resolvingSymlinksInPath().path.hasPrefix($0 + "/") }) else { continue }
                // Game-specific patched executables are game content, not helpers.
                if let exe = CompatibilityFixes.managedProgram(game), url.resolvingSymlinksInPath() == exe.resolvingSymlinksInPath() { continue }
                guard let sha = entry.shaAfter, sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
                if latest[entry.path].map({ $0.1.date <= entry.date }) ?? true { latest[entry.path] = (fix, entry) }
            }
        }
        return latest.values.sorted { $0.1.path < $1.1.path }
    }
    static func cache(_ game: InstalledGame) -> URL { game.nokcanduState.appendingPathComponent("repair-payloads") }
    static func snapshot(_ game: InstalledGame) {
        let folder = cache(game)
        guard folder.resolvingSymlinksInPath() == folder else { return }
        for (_, entry) in entries(game) {
            let file = URL(fileURLWithPath: entry.path), destination = folder.appendingPathComponent(entry.shaAfter!)
            guard file.resolvingSymlinksInPath() == file, destination.resolvingSymlinksInPath() == destination,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let size = attrs[.size] as? NSNumber, size.intValue <= 32_000_000,
                  let bytes = try? Data(contentsOf: file), Hashing.sha256(data: bytes) == entry.shaAfter else { continue }
            if (try? Hashing.sha256(file: destination)) != entry.shaAfter {
                try? NokPaths.ensure(folder); try? bytes.write(to: destination, options: .atomic)
            }
        }
    }
    static func repair(_ game: InstalledGame) -> [RepairStep] {
        snapshot(game)
        return entries(game).map { fix, entry in
            let file = URL(fileURLWithPath: entry.path), sha = entry.shaAfter!
            let title = "\(fix.title): \(file.lastPathComponent)"
            guard file.resolvingSymlinksInPath() == file else { return RepairStep(title: title, outcome: .skipped, detail: "Linked helper preserved.") }
            if (try? Hashing.sha256(file: file)) == sha { return RepairStep(title: title, outcome: .ok, detail: "Matches its installed compatibility component.") }
            // Unknown bytes may be a user/game update, so preserve them. Shared
            // generated helpers have their own stronger replacement policy.
            guard !FileManager.default.fileExists(atPath: file.path) else { return RepairStep(title: title, outcome: .skipped, detail: "Externally changed helper preserved. Undo/reinstall its compatibility component if needed.") }
            let payload = cache(game).appendingPathComponent(sha)
            guard payload.resolvingSymlinksInPath() == payload, let bytes = try? Data(contentsOf: payload), Hashing.sha256(data: bytes) == sha else {
                return RepairStep(title: title, outcome: .failed, detail: "Missing helper has no verified recovery copy. Reinstall its compatibility component; game files were preserved.")
            }
            do {
                try CompatibilityFixes.journal(fix, game).write(bytes, to: file, reason: "Repair: missing owned companion")
                if file.pathExtension == "exe" || file.lastPathComponent == NativeIPXNetworking.helperName { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
                guard try Hashing.sha256(file: file) == sha else { throw NokError("Restored helper failed verification.") }
                return RepairStep(title: title, outcome: .fixed, detail: "Restored a checksum-verified recovery copy without changing saved settings.")
            } catch { return RepairStep(title: title, outcome: .failed, detail: error.localizedDescription) }
        }
    }
}
