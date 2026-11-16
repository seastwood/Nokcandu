import Foundation

/// Controller profiles as files: one `.nokpad.json` each (the same text as Copy to Clipboard), and a zip holding
/// one file for every profile, to back them up, move them to another Mac or share them. Importing takes any mix of
/// those files, zips and folders of them. Settings only, like everything in a profile.
extension PadProfiles {
    public static let fileSuffix = ".nokpad.json"
    public static let archiveName = "Nokcandu Controller Profiles.zip"

    /// A file name for a profile: its name without what a file name can't hold, and unlike those already `taken`.
    public static func fileName(_ name: String, taken: inout Set<String>) -> String {
        var base = name.replacingOccurrences(of: #"[/:\\\x00-\x1f]"#, with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Profile" }
        var n = base, i = 2
        while !taken.insert(n.lowercased()).inserted { n = "\(base) (\(i))"; i += 1 }
        return n + fileSuffix
    }

    /// Each profile as a file of its own in `folder` (made if needed). A profile that builds on others carries
    /// them in its file, so any one file works alone.
    @discardableResult
    public static func exportFiles(_ profiles: [Profile], all: [Profile], to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken = Set<String>()
        return try profiles.map { p in
            let url = folder.appendingPathComponent(fileName(p.name, taken: &taken))
            try Data(exportText(p, all: all).utf8).write(to: url, options: .atomic)
            return url
        }
    }

    /// A zip with one file per profile, replacing `zip` if it is there.
    public static func exportArchive(_ profiles: [Profile], all: [Profile], to zip: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("NokcanduProfiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent("profiles", isDirectory: true)
        try exportFiles(profiles, all: all, to: folder)
        let made = work.appendingPathComponent("profiles.zip")
        let r = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", folder.path, made.path], timeout: 120)
        guard r.ok else { throw NokError("Couldn't make the zip: \(r.combined)") }
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        try fm.moveItem(at: made, to: zip)
    }

    /// Whether a zip holds controller profile files (by their names; nothing is unpacked).
    public static func archiveHasProfiles(_ zip: URL) -> Bool {
        guard let r = try? Shell.run("/usr/bin/unzip", ["-Z1", zip.path], timeout: 20), r.ok else { return false }
        return r.stdout.split(separator: "\n").contains { $0.lowercased().hasSuffix(fileSuffix) }
    }
    /// Whether a folder has controller profile files directly in it.
    public static func folderHasProfiles(_ folder: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.lowercased().hasSuffix(fileSuffix) }
    }
    /// Whether text is a shared controller profile.
    public static func isProfileText(_ text: String) -> Bool { (try? parseShared(text)) != nil }

    public struct Imported: Equatable, Sendable {
        /// New profiles, not yet stored; those others build on come first.
        public var added: [Profile] = []
        /// Names of profiles left out because the same profile is already here.
        public var alreadyHere: [String] = []
        /// Files that weren't controller profiles.
        public var unreadable: [String] = []
        public init(added: [Profile] = [], alreadyHere: [String] = [], unreadable: [String] = []) {
            self.added = added; self.alreadyHere = alreadyHere; self.unreadable = unreadable
        }
    }

    /// The profiles in these files: `.json` (or text) files, zips of them, and folders of them. Nothing is stored
    /// and nothing here is overwritten: see `merge`. Throws when none of it is a controller profile.
    public static func importFiles(_ urls: [URL], existing: [Profile]) throws -> Imported {
        let fm = FileManager.default
        var work: [URL] = []
        defer { for w in work { try? fm.removeItem(at: w) } }
        var files: [URL] = []
        func jsonFiles(under folder: URL) -> [URL] {
            let all = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            return all.filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix("._") && !$0.path.contains("/__MACOSX/") }
                .sorted { $0.path < $1.path }
        }
        var result = Imported()
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { result.unreadable.append(url.lastPathComponent); continue }
            if isDirectory.boolValue { files += jsonFiles(under: url) }
            else if url.pathExtension.lowercased() == "zip" {
                let out = fm.temporaryDirectory.appendingPathComponent("NokcanduProfiles-\(UUID().uuidString)", isDirectory: true)
                work.append(out)
                let r = try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, out.path], timeout: 120)
                let found = r.ok ? jsonFiles(under: out) : []
                if found.isEmpty { result.unreadable.append(url.lastPathComponent) }
                files += found
            } else { files.append(url) }
        }
        var lists: [[Profile]] = []
        for f in files {
            // (A profile file is small; anything large isn't one.)
            let size = ((try? fm.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 16 << 20, let text = try? String(contentsOf: f, encoding: .utf8), let list = try? parseShared(text) else {
                result.unreadable.append(f.lastPathComponent); continue
            }
            lists.append(list)
        }
        guard !lists.isEmpty else { throw NokError("That isn't a Nokcandu controller profile.") }
        let merged = merge(lists, existing: existing, skipIdentical: true)
        result.added = merged.added; result.alreadyHere = merged.alreadyHere
        return result
    }

    /// The profiles in shared text: a pack (a profile and those it builds on) or one profile's JSON, possibly
    /// inside a message's code block.
    public static func parseShared(_ text: String) throws -> [Profile] {
        struct Pack: Decodable { let nokcanduControllerProfiles: Int?; let profiles: [Profile] }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = body.range(of: #"```(?:json)?\s*\n[\s\S]*?```"#, options: .regularExpression) {
            body = String(body[r]).replacingOccurrences(of: #"^```(?:json)?\s*\n"#, with: "", options: .regularExpression).replacingOccurrences(of: "```", with: "")
        }
        let data = Data(body.utf8)
        let list: [Profile]
        if let pack = try? JSONDecoder().decode(Pack.self, from: data) { list = pack.profiles }
        else if let one = try? JSONDecoder().decode(Profile.self, from: data) { list = [one] }
        else { throw NokError("That isn't a Nokcandu controller profile.") }
        guard !list.isEmpty else { throw NokError("That isn't a Nokcandu controller profile.") }
        return list
    }

    /// Shared profiles made ready to add: new ids so nothing here is overwritten, names made unique, and what they
    /// build on pointing at the copies added with them. A profile in several of the lists (one that others build
    /// on is in each of their files) is added once. With `skipIdentical`, a profile that is already here under the
    /// same name with the same settings is left out, and what builds on it builds on the one here: so a backup
    /// can be imported again without doubling everything.
    public static func merge(_ lists: [[Profile]], existing: [Profile], skipIdentical: Bool) -> (added: [Profile], alreadyHere: [String]) {
        var pending: [Profile] = [], seen = Set<String>()
        for list in lists { for q in list where seen.insert(q.id).inserted { pending.append(q) } }
        var ids: [String: String] = [:]                 // a shared profile's id → the id it has here
        var names = Set(existing.map(\.name))
        var added: [Profile] = [], alreadyHere: [String] = []
        while !pending.isEmpty {
            let waiting = Set(pending.map(\.id))
            // Those whose own foundations are settled, so what they build on is known.
            var ready = pending.filter { q in !q.buildsOn.contains { $0 != q.id && waiting.contains($0) } }
            var compare = skipIdentical
            if ready.isEmpty {                          // profiles building on each other in a ring: taken as they are
                ready = pending; compare = false
                for q in ready { ids[q.id] = UUID().uuidString }
            }
            let taking = Set(ready.map(\.id))
            pending.removeAll { taking.contains($0.id) }
            for q in ready {
                var c = q
                c.buildsOn = q.buildsOn.compactMap { b in ids[b] ?? (existing.contains { $0.id == b } ? b : nil) }
                if compare, let same = existing.first(where: { e in e.name == q.name && { var x = c; x.id = e.id; return x == e }() }) {
                    ids[q.id] = same.id; alreadyHere.append(same.name); continue
                }
                c.id = ids[q.id] ?? UUID().uuidString
                ids[q.id] = c.id
                var n = q.name, i = 2
                while names.contains(n) { n = "\(q.name) (\(i))"; i += 1 }
                c.name = n; names.insert(n)
                added.append(c)
            }
        }
        return (added, alreadyHere)
    }
}
