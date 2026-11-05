import Foundation
import Darwin

/// Copies for moves that survive interruptions. A move copies into a hidden folder next to its destination
/// (`.<name>.nokcandu-moving`) and only renames it into place once every file has arrived. If the copy stops
/// before that (Nokcandu quit, the Mac slept or restarted, a drive was unplugged), the partial copy and a
/// small record stay behind; moving the game to the same place again continues from there instead of starting
/// over. Files count as already copied only when their size and modification date match the original
/// (a file cut off mid-copy never gets the original's date), and the finished copy is checked as before.
public enum ResumableCopy {
    public struct Record: Codable, Hashable, Sendable {
        public var source: String
        public var partial: String
        public var total: Int64
        public var started: Date
    }

    nonisolated(unsafe) static var testRecords: URL?
    static var recordsFolder: URL { testRecords ?? NokPaths.support.appendingPathComponent("Interrupted Moves", isDirectory: true) }
    static func recordFile(partial: URL) -> URL {
        recordsFolder.appendingPathComponent(Hashing.sha256(data: Data(partial.standardizedFileURL.path.utf8)).prefix(24) + ".json")
    }

    /// Unfinished copies whose partial folder still exists.
    public static func interrupted() -> [Record] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: recordsFolder, includingPropertiesForKeys: nil)) ?? []).compactMap { f in
            guard f.pathExtension == "json", let data = try? Data(contentsOf: f),
                  let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            guard fm.fileExists(atPath: r.partial) else {
                // Its drive may just be unplugged: forget it only once the partial is known gone.
                let volume = (try? URL(fileURLWithPath: r.partial).deletingLastPathComponent().resourceValues(forKeys: [.volumeURLKey]))?.volume
                if volume != nil, fm.fileExists(atPath: URL(fileURLWithPath: r.partial).deletingLastPathComponent().path) { try? fm.removeItem(at: f) }
                return nil
            }
            return r
        }
    }

    /// The unfinished copy of `source`, if one exists (for the Move window to mention).
    public static func interrupted(source: URL) -> Record? {
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        return interrupted().first { $0.source == path }
    }

    /// Deletes an unfinished copy (Free Up Space).
    public static func discard(_ r: Record) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: r.partial) { try fm.removeItem(atPath: r.partial) }
        try? fm.removeItem(at: recordFile(partial: URL(fileURLWithPath: r.partial)))
    }

    /// Bytes still to copy into `partial` (for the free-space check).
    static func remaining(source: URL, partial: URL, total: Int64) -> Int64 {
        guard resumable(source: source, partial: partial) else { return total }
        return max(0, total - Storage.allocatedSize(partial))
    }

    static func resumable(source: URL, partial: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: partial.path),
              let data = try? Data(contentsOf: recordFile(partial: partial)),
              let r = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return r.source == source.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Copies `source` into `partial`. Continues an earlier unfinished copy of the same source; anything else
    /// already at `partial` is replaced. `plain`: without Mac-only extras (for ExFAT and similar drives).
    /// Throws without removing the partial copy, so the next attempt can continue it.
    public static func copy(_ source: URL, into partial: URL, total: Int64, plain: Bool) throws {
        let fm = FileManager.default
        let resume = resumable(source: source, partial: partial)
        if !resume, fm.fileExists(atPath: partial.path) || (try? fm.destinationOfSymbolicLink(atPath: partial.path)) != nil {
            try fm.removeItem(at: partial)
        }
        try NokPaths.ensure(recordsFolder)
        let record = Record(source: source.resolvingSymlinksInPath().standardizedFileURL.path,
                            partial: partial.standardizedFileURL.path, total: total, started: Date())
        if !resume { try JSONEncoder().encode(record).write(to: recordFile(partial: partial), options: .atomic) }
        if !resume {
            // A fresh copy: ditto is fastest and keeps everything Finder would.
            let args = plain ? ["--norsrc", "--noextattr", "--noacl", source.path, partial.path] : [source.path, partial.path]
            let r = try Shell.run("/usr/bin/ditto", args, timeout: 12 * 3600)
            if r.ok { return }
            // ditto can stop on details a drive can't store (ExFAT "Invalid argument"): continue file by file.
            if !fm.fileExists(atPath: partial.path) { throw NokError("Copying failed: \(r.combined.suffix(300))") }
        }
        try copyMissing(source, into: partial, plain: plain)
    }

    /// Called once the copy is checked and renamed into place.
    public static func finished(partial: URL) {
        try? FileManager.default.removeItem(at: recordFile(partial: partial))
    }

    /// File-by-file copy that skips files already present with the original's size and date, replaces cut-off
    /// ones and removes anything the original no longer has.
    static func copyMissing(_ source: URL, into dest: URL, plain: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var wanted = Set<String>()
        let flags = copyfile_flags_t(plain ? (COPYFILE_DATA | COPYFILE_STAT) : (COPYFILE_ALL | COPYFILE_CLONE)) | copyfile_flags_t(COPYFILE_NOFOLLOW)
        guard let e = fm.enumerator(atPath: source.path) else { throw NokError("Can't read \(source.path).") }
        var failures: [String] = []
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if plain, name == ".DS_Store" || name.hasPrefix("._") { continue }
            wanted.insert(rel)
            let from = source.appendingPathComponent(rel).path, to = dest.appendingPathComponent(rel).path
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0 else { continue }
            let have = lstat(to, &b) == 0
            switch a.st_mode & S_IFMT {
            case S_IFDIR:
                if have, b.st_mode & S_IFMT == S_IFDIR { continue }
                if have { try? fm.removeItem(atPath: to) }
                try fm.createDirectory(atPath: to, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(a.st_mode & 0o7777)])
            case S_IFLNK:
                let target = try fm.destinationOfSymbolicLink(atPath: from)
                if have, (try? fm.destinationOfSymbolicLink(atPath: to)) == target { continue }
                if have { try? fm.removeItem(atPath: to) }
                try fm.createSymbolicLink(atPath: to, withDestinationPath: target)
            case S_IFREG:
                if have, b.st_mode & S_IFMT == S_IFREG, b.st_size == a.st_size,
                   abs(b.st_mtimespec.tv_sec - a.st_mtimespec.tv_sec) <= 2 { continue }
                if have { try? fm.removeItem(atPath: to) }
                if copyfile(from, to, nil, flags) != 0 {
                    // Some drives refuse details (permissions, dates) the data copy doesn't need.
                    if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW)) != 0 {
                        failures.append(rel); continue
                    }
                    var times = [timespec(tv_sec: a.st_atimespec.tv_sec, tv_nsec: 0), timespec(tv_sec: a.st_mtimespec.tv_sec, tv_nsec: 0)]
                    _ = utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW)
                }
            default: continue
            }
        }
        if !failures.isEmpty {
            throw NokError("Couldn't copy \(failures.count) file\(failures.count == 1 ? "" : "s") (first: \(failures[0])). The copy so far is kept; moving again continues it.")
        }
        // Remove what the original no longer has (deepest first).
        if let d = fm.enumerator(atPath: dest.path) {
            var extra: [String] = []
            while let rel = d.nextObject() as? String {
                if !wanted.contains(rel) { extra.append(rel); d.skipDescendants() }
            }
            for rel in extra.reversed() { try? fm.removeItem(at: dest.appendingPathComponent(rel)) }
        }
    }
}
