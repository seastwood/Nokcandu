import Foundation
import Darwin

/// One copy of each Wine engine file per drive.
///
/// On the Mac every app's engine is an APFS clone of Nokcandu's engines cache, so it is stored once. Copied to
/// another drive (an APFS games volume), each app carried a full ~1.5 GB copy. Here identical engine files on the
/// same drive are turned back into clones of one another, through a small content-addressed store on that drive
/// (`.Nokcandu Shared Engine Files/<sha256>`), which costs nothing extra: its files are clones too.
/// Only byte-identical files are shared (checked by SHA-256), so engines Nokcandu adjusted per game (window or
/// audio drivers) keep their own versions. The game's files, Windows setup and saves are never touched.
public enum EngineShare {
    static let folderName = ".Nokcandu Shared Engine Files"
    /// Small files aren't worth a clone each.
    static let minimumSize: Int64 = 16 * 1024

    /// The drive's root, for drives other than the startup disk (where apps already share the engines cache).
    /// Tests: treat this folder as a separate drive.
    nonisolated(unsafe) static var testRoot: URL?
    static func volumeRoot(_ url: URL) -> URL? {
        if let t = testRoot { return url.resolvingSymlinksInPath().path.hasPrefix(t.resolvingSymlinksInPath().path + "/") ? t : nil }
        guard let root = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL,
              root.path != "/", GameFolders.holdsApps(root) else { return nil }
        return root
    }
    static func store(_ root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    /// Engine files of an app (regular files of a useful size, links excluded).
    static func engineFiles(_ app: URL) -> [URL] {
        let fm = FileManager.default
        let contents = app.resolvingSymlinksInPath().appendingPathComponent("Contents")
        var out: [URL] = []
        for comp in RuntimeManager.components {
            let dir = contents.appendingPathComponent(comp)
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true, Int64(v.fileSize ?? 0) >= minimumSize else { continue }
                out.append(u)
            }
        }
        return out
    }

    /// Bytes of engine files on this app's drive that aren't shared with anything yet (what sharing could save
    /// once another app on the drive has the same files).
    public static func unsharedBytes(_ app: URL) -> Int64 {
        engineFiles(app).reduce(0) { $0 + (Storage.privateSize($1) ?? 0) }
    }

    /// Shares this app's engine files with identical ones already on its drive. Returns bytes freed. The app and
    /// everything running in its Windows environment must be closed.
    @discardableResult
    public static func share(app: URL, progress: (String) -> Void = { _ in }) throws -> Int64 {
        let fm = FileManager.default
        let real = app.resolvingSymlinksInPath()
        guard let root = volumeRoot(real) else { return 0 }
        let contents = real.appendingPathComponent("Contents")
        if !WineTools.ownedProcesses(contents: contents).isEmpty { throw NokError("Quit \(real.deletingPathExtension().lastPathComponent) first.") }
        let cache = store(root)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var freed: Int64 = 0
        let files = engineFiles(real)
        for (i, file) in files.enumerated() {
            if i % 200 == 0 { progress("Sharing engine files (\(i) of \(files.count))…") }
            guard let privateBytes = Storage.privateSize(file), privateBytes > 0,
                  let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let hash = try? Hashing.sha256(file: file) else { continue }
            let cached = cache.appendingPathComponent(hash)
            if let cachedSize = (try? fm.attributesOfItem(atPath: cached.path))?[.size] as? NSNumber, cachedSize.int64Value == size,
               (try? Hashing.sha256(file: cached)) == hash {
                // Replace the file with a clone of the shared copy (atomically, keeping its permissions and date).
                let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).nokcandu-share")
                try? fm.removeItem(at: tmp)
                guard clonefile(cached.path, tmp.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else { continue }
                var keep: [FileAttributeKey: Any] = [:]
                if let p = attrs[.posixPermissions] { keep[.posixPermissions] = p }
                if let d = attrs[.modificationDate] { keep[.modificationDate] = d }
                try? fm.setAttributes(keep, ofItemAtPath: tmp.path)
                if rename(tmp.path, file.path) == 0 { freed += privateBytes } else { try? fm.removeItem(at: tmp) }
            } else if !fm.fileExists(atPath: cached.path) {
                // First of its kind on this drive: the shared copy is a clone of this one (no extra space).
                _ = clonefile(file.path, cached.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY))
            }
        }
        return freed
    }

    /// Shares engine files between every closed app on a drive. Returns (bytes freed, apps skipped because running).
    public static func shareAll(on root: URL, library: [InstalledGame], progress: (String) -> Void = { _ in }) -> (Int64, [String]) {
        var freed: Int64 = 0, skipped: [String] = []
        var seen = Set<String>()
        for g in library where g.native == nil {
            guard let host = WineTools.hostContents(for: g)?.deletingLastPathComponent().resolvingSymlinksInPath(),
                  seen.insert(host.path).inserted, volumeRoot(host)?.path == root.path else { continue }
            progress("Sharing \(host.deletingPathExtension().lastPathComponent)'s engine files…")
            do { freed += try share(app: host, progress: progress) } catch { skipped.append(host.deletingPathExtension().lastPathComponent) }
        }
        prune(root)
        return (freed, skipped)
    }

    /// Removes shared copies no app uses any more (a copy whose blocks nothing else shares).
    @discardableResult
    public static func prune(_ root: URL) -> Int {
        let fm = FileManager.default
        var removed = 0
        for f in (try? fm.contentsOfDirectory(at: store(root), includingPropertiesForKeys: nil)) ?? [] {
            guard let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? NSNumber, size.int64Value > 0,
                  let p = Storage.privateSize(f), p >= size.int64Value else { continue }
            if (try? fm.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }

    /// Drives other than the Mac's whose apps hold at least `minimum` of unshared engine files: (drive, bytes, apps).
    public static func candidates(library: [InstalledGame], minimum: Int64 = 500_000_000) -> [(root: URL, bytes: Int64, apps: Int)] {
        var byRoot: [String: (URL, Int64, Int, Int64)] = [:]   // root → (url, total, apps, largest)
        var seen = Set<String>()
        for g in library where g.native == nil {
            guard let host = WineTools.hostContents(for: g)?.deletingLastPathComponent().resolvingSymlinksInPath(),
                  seen.insert(host.path).inserted, let root = volumeRoot(host) else { continue }
            let bytes = unsharedBytes(host)
            var entry = byRoot[root.path] ?? (root, 0, 0, 0)
            entry.1 += bytes; entry.2 += 1; entry.3 = max(entry.3, bytes)
            byRoot[root.path] = entry
        }
        // One copy of each file stays; roughly the largest app's worth when nothing is shared yet.
        let cacheExists = { (r: URL) in FileManager.default.fileExists(atPath: store(r).path) }
        return byRoot.values.compactMap { r, total, apps, largest in
            let saving = cacheExists(r) ? total : total - largest
            return apps >= 1 && saving >= minimum ? (r, saving, apps) : nil
        }
    }
}
