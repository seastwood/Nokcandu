import Foundation

/// Disc images for games that came on discs — one or several. Every disc is kept inside the game's app;
/// drive D: holds one at a time and can be swapped while the game or its installer runs, like a real CD
/// drive (Windows sees D: change). .bin/.cue, .img/.ccd and .mdf images are converted to .iso first.
public enum Discs {
    public static let imageTypes = ["iso", "cdr", "bin", "cue", "img", "ccd", "mdf", "mds"]

    /// All discs of a game, in order (Disc 1 first).
    public static func all(_ c: CustomGameConfig) -> [DiscSpec] { (c.disc.map { [$0] } ?? []) + (c.extraDiscs ?? []) }

    /// Where disc n (0-based) is mounted inside the app: MountedDisc, MountedDisc2, MountedDisc3…
    public static func mountDir(_ support: URL, index: Int) -> URL {
        support.appendingPathComponent(index == 0 ? "MountedDisc" : "MountedDisc\(index + 1)", isDirectory: true)
    }

    static func currentFile(_ support: URL) -> URL { support.appendingPathComponent("nokcandu/current-disc") }

    /// Which disc is in D: (0-based; the launcher uses the same file).
    public static func current(support: URL) -> Int {
        Int(((try? String(contentsOf: currentFile(support), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Importing (and converting) images

    public struct Imported: Equatable { public var imageName: String; public var label: String; public var note: String? }

    /// Copies (or converts) a disc image into `support` as .iso/.cdr and reads its volume label.
    public static func importImage(_ src: URL, into support: URL, log: (String) -> Void = { _ in }) throws -> Imported {
        let fm = FileManager.default
        var url = src
        var note: String?
        let ext = src.pathExtension.lowercased()
        // Companion files: open the image they describe.
        if ext == "ccd" || ext == "mds" {
            let partner = src.deletingPathExtension().appendingPathExtension(ext == "ccd" ? "img" : "mdf")
            let alt = src.deletingPathExtension().appendingPathExtension(ext == "ccd" ? "IMG" : "MDF")
            guard let found = [partner, alt].first(where: { fm.fileExists(atPath: $0.path) }) else {
                throw NokError("Couldn't find \(partner.lastPathComponent) next to \(src.lastPathComponent).")
            }
            url = found
        }
        let base = CustomGames.safeFolderName(src.deletingPathExtension().lastPathComponent)
        var dest: URL
        if ["iso", "cdr"].contains(url.pathExtension.lowercased()) {
            dest = support.appendingPathComponent(base + "." + url.pathExtension.lowercased())
            if !fm.fileExists(atPath: dest.path) { log("Keeping a copy of \(src.lastPathComponent) inside the app…"); try fm.cloneItem(at: url, to: dest) }
        } else {
            var track = url, layout: Layout?
            if url.pathExtension.lowercased() == "cue" {
                let (file, mode, audio) = try parseCue(url)
                track = file; layout = mode
                if audio { note = "This disc's CD-audio music tracks can't be used under Wine; the game's data is all there." }
            }
            guard let l = try layout ?? detectLayout(track) else {
                throw NokError("\(src.lastPathComponent) isn't a disc image format Nokcandu can read (audio-only or unusual layout).")
            }
            dest = support.appendingPathComponent(base + ".iso")
            if !fm.fileExists(atPath: dest.path) {
                log("Converting \(src.lastPathComponent) to a standard disc image…")
                try convert(track, layout: l, to: dest)
            }
        }
        return Imported(imageName: dest.lastPathComponent, label: try volumeLabel(dest), note: note)
    }

    /// Raw CD sector layout: bytes per sector and where the 2048 data bytes start.
    struct Layout: Equatable { var sectorSize: Int; var dataOffset: Int }

    static func parseCue(_ cue: URL) throws -> (URL, Layout?, Bool) {
        let text = try String(contentsOf: cue, encoding: .isoLatin1)
        var file: String?, layout: Layout?, audio = false, firstDataSeen = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let up = line.uppercased()
            if up.hasPrefix("FILE ") {
                if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
                    let name = String(line[line.index(after: a)..<b])
                    if !firstDataSeen { file = name }
                }
            } else if up.hasPrefix("TRACK ") {
                if up.contains("AUDIO") { audio = true; continue }
                if firstDataSeen { continue }
                firstDataSeen = true
                if up.contains("MODE1/2048") { layout = Layout(sectorSize: 2048, dataOffset: 0) }
                else if up.contains("MODE1/2352") { layout = Layout(sectorSize: 2352, dataOffset: 16) }
                else if up.contains("MODE2/2352") { layout = Layout(sectorSize: 2352, dataOffset: 24) }
                else if up.contains("MODE2/2336") { layout = Layout(sectorSize: 2336, dataOffset: 8) }
            }
        }
        guard let file else { throw NokError("\(cue.lastPathComponent) doesn't name a data track file.") }
        let dir = cue.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let hit = names.first { $0.caseInsensitiveCompare((file as NSString).lastPathComponent) == .orderedSame } ?? file
        return (dir.appendingPathComponent(hit), layout, audio)
    }

    /// Recognizes raw CD images by the 12-byte sector sync pattern (2352 or 2448 bytes per sector).
    static func detectLayout(_ f: URL) throws -> Layout? {
        let h = try FileHandle(forReadingFrom: f)
        defer { try? h.close() }
        let head = h.readData(ofLength: 2448 * 2 + 32)
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        func syncAt(_ o: Int) -> Bool { head.count >= o + 16 && Array(head[o..<o + 12]) == sync }
        for size in [2352, 2448] where syncAt(0) && syncAt(size) {
            return Layout(sectorSize: size, dataOffset: head[15] == 2 ? 24 : 16)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        return size > 0 && size % 2048 == 0 ? Layout(sectorSize: 2048, dataOffset: 0) : nil
    }

    static func convert(_ src: URL, layout l: Layout, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = dest.appendingPathExtension("part")
        try? fm.removeItem(at: tmp)
        if l.sectorSize == 2048 { try fm.copyItem(at: src, to: tmp) }
        else {
            fm.createFile(atPath: tmp.path, contents: nil)
            let input = try FileHandle(forReadingFrom: src), output = try FileHandle(forWritingTo: tmp)
            defer { try? input.close(); try? output.close() }
            let per = 512
            while true {
                let chunk = input.readData(ofLength: l.sectorSize * per)
                if chunk.isEmpty { break }
                var out = Data(capacity: 2048 * per)
                var o = 0
                while o + l.dataOffset + 2048 <= chunk.count {
                    out.append(chunk.subdata(in: (o + l.dataOffset)..<(o + l.dataOffset + 2048)))
                    o += l.sectorSize
                }
                output.write(out)
            }
        }
        try fm.moveItem(at: tmp, to: dest)
    }

    /// Disc images macOS has open now: image path → mount points.
    static func attached() -> [String: [String]] {
        guard let out = try? Shell.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30).stdout,
              let dict = (try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil)) as? [String: Any],
              let images = dict["images"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for i in images {
            guard let path = i["image-path"] as? String else { continue }
            let mounts = ((i["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["mount-point"] as? String }
            map[real(path), default: []] += mounts.map(real)
        }
        return map
    }

    /// The real path (symlinks resolved, e.g. /var → /private/var), as macOS reports mount points.
    static func real(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    static func label(at mount: String) -> String? {
        let plist = (try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", mount]))?.stdout ?? ""
        return ((try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any])?["VolumeName"] as? String
    }

    static func volumeLabel(_ image: URL) throws -> String {
        // Already open (e.g. still in drive D: from an earlier try): read it there — a second attach fails.
        if let m = attached()[real(image.path)]?.first { return label(at: m) ?? "" }
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("nokcandu-disc-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", probe.path, "-quiet"]); try? fm.removeItem(at: probe) }
        let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", probe.path, image.path], timeout: 120)
        guard r.ok else { throw NokError("macOS couldn't open \(image.lastPathComponent): \(r.combined)") }
        let plist = (try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", probe.path]))?.stdout ?? ""
        return ((try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any])?["VolumeName"] as? String ?? ""
    }

    // MARK: Drive D:

    /// Puts disc `index` in drive D: — mounts it (read-only, hidden from Finder) if needed and points
    /// D: (files) and D:: (raw device) at it. Works while the game or its installer is running.
    public static func insert(_ index: Int, images: [String], support: URL, prefix: URL) throws {
        guard images.indices.contains(index) else { throw NokError("There's no disc \(index + 1).") }
        let fm = FileManager.default
        let mount = mountDir(support, index: index)
        func info(_ key: String) -> String? {
            let plist = (try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", mount.path]))?.stdout ?? ""
            return ((try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any])?[key] as? String
        }
        let image = real(support.appendingPathComponent(images[index]).path)
        let open = attached()
        let here = real(mount.path)
        func mountedHere() -> Bool { info("MountPoint").map(real) == here }
        if mountedHere(), !(open[image] ?? []).contains(here) {
            // A different disc is mounted in this disc's folder (an earlier try or another order): take it out.
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60)
        }
        if !mountedHere() {
            // The same image open somewhere else (Finder, another folder) can't be opened twice: close that first.
            for m in open[image] ?? [] { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", m, "-force"], timeout: 60) }
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            // Right after a detach macOS can still be releasing the image ("Permission denied"/"busy"): retry briefly.
            var r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image], timeout: 120)
            for _ in 0..<6 where !r.ok {
                Thread.sleep(forTimeInterval: 0.5)
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image], timeout: 120)
            }
            guard r.ok else {
                let why = r.combined.components(separatedBy: "\n").filter { !$0.contains("deprecated") && !$0.isEmpty }.joined(separator: " ")
                throw NokError("macOS couldn't mount disc \(index + 1): \(why)")
            }
        }
        guard let node = info("DeviceNode") else { throw NokError("Disc \(index + 1) mounted, but its device couldn't be identified.") }
        let dos = prefix.appendingPathComponent("dosdevices")
        for (name, dest) in [("d:", mount.path), ("d::", "/dev/r" + node.dropFirst("/dev/".count))] {
            let link = dos.appendingPathComponent(name)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: dest)
        }
        try fm.createDirectory(at: currentFile(support).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(index)\n".write(to: currentFile(support), atomically: true, encoding: .utf8)
    }

    public static func insert(_ index: Int, for g: InstalledGame) throws {
        guard let c = g.custom else { return }
        try insert(index, images: all(c).map(\.imageName), support: g.support, prefix: g.prefix)
    }

    /// Adds more discs to a game (e.g. Disc 2 after installing from Disc 1). Returns the settings to save.
    public static func add(_ urls: [URL], to g: InstalledGame, current: CustomGameConfig) throws -> (CustomGameConfig, [String]) {
        var c = current, notes: [String] = []
        for u in urls {
            let i = try importImage(u, into: g.support)
            if let n = i.note { notes.append(n) }
            if all(c).contains(where: { $0.imageName == i.imageName }) { continue }
            let spec = DiscSpec(imageName: i.imageName, volumeLabel: i.label, internalMountDir: "SharedSupport/MountedDisc")
            if c.disc == nil { c.disc = spec } else { c.extraDiscs = (c.extraDiscs ?? []) + [spec] }
        }
        return (c, notes)
    }

    /// Orders picked files as Disc 1, 2, 3… by the number in their names ("Disc 2", "CD2", "_2"). Without
    /// numbers, the base game comes first: a name the others extend ("Morrowind" before "Morrowind Tribunal").
    public static func sorted(_ urls: [URL]) -> [URL] {
        func base(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent.lowercased() }
        func n(_ u: URL) -> Int? {
            let s = base(u)
            if let m = s.firstMatch(of: #/(?:disc|disk|cd)\s*[_\- ]?\s*(\d+)/#) { return Int(m.1) }
            if let m = s.firstMatch(of: #/[^0-9](\d)\s*$/#) { return Int(m.1) }
            return nil
        }
        // Companion files (.cue's .bin, .ccd's .img) are opened through their descriptor.
        let kept = urls.filter { u in
            let e = u.pathExtension.lowercased(), b = base(u)
            if e == "bin" { return !urls.contains { $0.pathExtension.lowercased() == "cue" && base($0) == b } }
            if e == "img" || e == "mdf" { return !urls.contains { ["ccd", "mds"].contains($0.pathExtension.lowercased()) && base($0) == b } }
            return true
        }
        func rank(_ u: URL) -> (Int, Int, String) {
            if let k = n(u) { return (k, 0, base(u)) }
            let b = base(u)
            let isBase = kept.contains { $0 != u && base($0).hasPrefix(b) && base($0) != b }
            return (isBase ? 0 : 1000, b.count, b)
        }
        return kept.sorted { rank($0) < rank($1) }
    }

    /// Runs the setup program of disc `index` (puts it in D: first) and waits until every program it
    /// started has finished — disc menus (autorun) hand off to the real setup and exit right away.
    public static func runSetup(_ index: Int, images: [String], support: URL, prefix: URL, env: [String: String],
                                log: @escaping @Sendable (String) -> Void) async throws {
        try insert(index, images: images, support: support, prefix: prefix)
        let mount = mountDir(support, index: index)
        guard let setup = setupProgram(mount) else {
            throw NokError("Disc \(index + 1) has no setup program. If it's a data disc, the game reads it from drive D: while playing.")
        }
        let wine = support.appendingPathComponent("wine/bin/wine").path
        log("Starting D:\\\(setup) from disc \(index + 1). Finish it in its own window…")
        let r = try await Shell.runAsync(wine, ["start", "/wait", "/d", "D:\\", "D:\\" + setup.replacingOccurrences(of: "/", with: "\\")],
                                         cwd: mount, env: env, timeout: 4 * 3600) { s in log(s.trimmingCharacters(in: .newlines)) }
        log("Disc \(index + 1)'s menu or setup closed (exit \(r.status)); waiting for any setup it started…")
        _ = try? await Shell.runAsync(support.appendingPathComponent("wine/bin/wineserver").path, ["-w"], env: env, timeout: 4 * 3600)
        log("Disc \(index + 1) setup finished.")
    }

    /// autorun.inf's open= program, else setup/install/autorun at the disc root.
    public static func setupProgram(_ mount: URL) -> String? { CustomInstall.Acquire.discSetup(mount) }
}
