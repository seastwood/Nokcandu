import Foundation

/// An APFS games volume on an ExFAT drive. Whole game apps (Wine engine, Windows setup, saves) need a
/// Mac-formatted drive, and ExFAT also wastes space on games with many small files. Rather than erase or
/// repartition the drive, Nokcandu keeps a growable disk image (APFS sparse bundle) on it: it takes only
/// the space its contents use, appears as its own drive while connected, and is opened automatically
/// whenever the drive is plugged in.
public enum GamesVolume {
    public struct Drive: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public var name: String
        public var url: URL
        public var format: String
        public var free: Int64
        /// ExFAT/FAT: game files only, unless it hosts an APFS games volume.
        public var holdsApps: Bool
        public var images: [Image]
    }
    public struct Image: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public var url: URL
        public var name: String
        /// Where it's open right now (nil: not open).
        public var mountPoint: URL?
        public var automatic: Bool
    }

    /// Mounted drives other than the startup disk, with any games volumes stored on them.
    public static func drives() -> [Drive] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let attached = attachedImages()
        let registered = Set(AutoMount.images().map(\.path))
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true, v.volumeIsBrowsable != false,
                  v.volumeIsReadOnly != true, u.path.hasPrefix("/Volumes/") else { return nil }
            // Disk images (a games volume itself, simulators…) aren't drives to put one on.
            if attached.values.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { return nil }
            let images = findImages(on: u).map { Image(url: $0, name: $0.deletingPathExtension().lastPathComponent,
                                                      mountPoint: attached[$0.standardizedFileURL.path], automatic: registered.contains($0.path)) }
            return Drive(name: v.volumeName ?? u.lastPathComponent, url: u, format: v.volumeLocalizedFormatDescription ?? "?",
                         free: GameFolders.freeSpace(u) ?? 0, holdsApps: GameFolders.holdsApps(u), images: images)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// APFS sparse bundles at the top of a drive (where Nokcandu puts them, and where people usually do).
    static func findImages(on drive: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: drive, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "sparsebundle" }
    }

    /// image path → where it's mounted, from `hdiutil info`.
    public static func attachedImages() -> [String: URL] {
        guard let r = try? Shell.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 20), r.ok,
              let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var out: [String: URL] = [:]
        for image in images {
            guard let path = image["image-path"] as? String else { continue }
            let mount = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }.first
            if let mount { out[URL(fileURLWithPath: path).standardizedFileURL.path] = URL(fileURLWithPath: mount, isDirectory: true) }
        }
        return out
    }

    public static func validName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60, !n.contains("/"), !n.contains(":"), !n.hasPrefix(".") else { return nil }
        return n
    }

    /// Makes the volume, opens it, adds a "Nokcandu Games" library folder in it and has it open by itself
    /// whenever the drive is connected. Returns that library folder.
    public static func create(on drive: URL, name: String, maxBytes: Int64, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        guard let name = validName(name) else { throw NokError("Choose a name without slashes or colons.") }
        let image = drive.appendingPathComponent(name + ".sparsebundle", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: image.path) else { throw NokError("\(drive.lastPathComponent) already has \(image.lastPathComponent). Use it instead, or pick another name.") }
        guard FileManager.default.isWritableFile(atPath: drive.path) else { throw NokError("Nokcandu can't write to \(drive.lastPathComponent).") }
        if FileManager.default.fileExists(atPath: "/Volumes/" + name) { throw NokError("A drive called “\(name)” is already connected. Pick another name.") }
        let gigabytes = max(10, maxBytes / 1_000_000_000)
        progress("Creating \(name)…")
        let r = try Shell.run("/usr/bin/hdiutil", ["create", "-size", "\(gigabytes)g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                                   "-volname", name, image.path], timeout: 600)
        guard r.ok else { throw NokError("macOS couldn't create the volume: \(r.combined.suffix(300))") }
        progress("Opening it…")
        let mount = try attach(image)
        let library = try GameFolders.add(mount)
        AutoMount.register(image)
        return library
    }

    /// Uses a games volume that already exists (made by hand or on another Mac): opens it, adds its library
    /// folder and opens it automatically from now on.
    public static func adopt(_ image: URL) throws -> URL {
        let mount = try attachedImages()[image.standardizedFileURL.path] ?? attach(image)
        guard GameFolders.holdsApps(mount) else { throw NokError("\(image.lastPathComponent) isn't Mac-formatted (APFS or Mac OS Extended).") }
        let library = try GameFolders.add(mount)
        AutoMount.register(image)
        return library
    }

    /// macOS leaves Spotlight off on disk-image volumes, so games stored there were missing from Spotlight and
    /// the Apps launcher. Turning it on needs no administrator rights.
    public static func enableIndexing(_ mount: URL) {
        guard let status = try? Shell.run("/usr/bin/mdutil", ["-s", mount.path], timeout: 20), status.combined.contains("disabled") else { return }
        _ = try? Shell.run("/usr/bin/mdutil", ["-i", "on", mount.path], timeout: 60)
    }

    @discardableResult
    public static func attach(_ image: URL) throws -> URL {
        if let existing = attachedImages()[image.standardizedFileURL.path] { enableIndexing(existing); return existing }
        let r = try Shell.run("/usr/bin/hdiutil", ["attach", image.path, "-noautoopen", "-plist"], timeout: 180)
        guard r.ok, let plist = try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any],
              let mount = (plist["system-entities"] as? [[String: Any]] ?? []).compactMap({ $0["mount-point"] as? String }).first else {
            throw NokError("macOS couldn't open \(image.lastPathComponent): \(r.combined.suffix(300))")
        }
        let url = URL(fileURLWithPath: mount, isDirectory: true)
        enableIndexing(url)
        return url
    }

    /// Opens every registered games volume whose drive is connected (Nokcandu does this whenever a drive
    /// appears; the login helper does it while Nokcandu is closed). Returns the ones it opened.
    @discardableResult
    public static func attachRegistered() -> [URL] {
        let attached = attachedImages()
        for image in AutoMount.images() { if let m = attached[image.standardizedFileURL.path] { enableIndexing(m) } }
        return AutoMount.images().filter { FileManager.default.fileExists(atPath: $0.path) && attached[$0.standardizedFileURL.path] == nil }
            .compactMap { try? attach($0) }
    }

    /// Removes a games volume that holds no games: closes it, stops opening it automatically, forgets its library
    /// folder and moves the image to the Trash (so it can still be recovered until the Trash is emptied).
    public static func remove(_ image: URL, library: [InstalledGame]) throws {
        let fm = FileManager.default
        let mount = attachedImages()[image.standardizedFileURL.path]
        if let mount {
            let inside = library.filter { $0.appURL.resolvingSymlinksInPath().path.hasPrefix(mount.resolvingSymlinksInPath().path + "/")
                || (GameMover.externalFiles($0)?.path.hasPrefix(mount.path + "/") ?? false) }
            if let g = inside.first { throw NokError("\(g.name) is stored in \(mount.lastPathComponent). Move it out first.") }
            for folder in GameFolders.all where folder.path.hasPrefix(mount.path + "/") || folder.path == mount.path { GameFolders.remove(folder) }
            let r = try Shell.run("/usr/sbin/diskutil", ["eject", mount.path], timeout: 120)
            guard r.ok else { throw NokError("\(mount.lastPathComponent) is in use: \(r.combined.suffix(200))") }
        }
        AutoMount.unregister(image)
        try SystemIntegration.trash(image)
    }

    /// Ejects a drive safely: closes the games volumes stored on it first (macOS refuses otherwise).
    public static func eject(_ drive: URL) throws {
        for (path, mount) in attachedImages() where path.hasPrefix(drive.standardizedFileURL.path + "/") {
            let r = try Shell.run("/usr/sbin/diskutil", ["eject", mount.path], timeout: 120)
            guard r.ok else { throw NokError("\(mount.lastPathComponent) is in use" + (dissenter(r.combined).map { " by \($0)" } ?? "") + ". Quit games and launchers stored on it, and anything else using it, then eject again.") }
        }
        let r = try Shell.run("/usr/sbin/diskutil", ["eject", drive.path], timeout: 120)
        guard r.ok else {
            if let who = dissenter(r.combined) { throw NokError("\(drive.lastPathComponent) is in use by \(who). Quit it (or close what it has open there), then eject again.") }
            throw NokError("macOS couldn't eject \(drive.lastPathComponent): \(r.combined.suffix(200))")
        }
    }

    /// The program that refused an unmount ("Unmount was dissented by PID 123 (/path/App.app/Contents/MacOS/App)"),
    /// by its app's name when it's inside one.
    static func dissenter(_ output: String) -> String? {
        guard let r = output.range(of: #"dissented by PID \d+ \(([^)]+)\)"#, options: .regularExpression) else { return nil }
        let match = String(output[r])
        guard let open = match.firstIndex(of: "("), let close = match.lastIndex(of: ")") else { return nil }
        let path = String(match[match.index(after: open)..<close])
        let parts = path.split(separator: "/").map(String.init)
        // The outermost app in the path (an XPC service inside a framework counts as its framework).
        if let app = parts.first(where: { $0.hasSuffix(".app") }) { return (app as NSString).deletingPathExtension }
        if let framework = parts.first(where: { $0.hasSuffix(".framework") }) { return (framework as NSString).deletingPathExtension + " (a macOS service)" }
        return parts.last
    }
}

/// Opens registered games volumes whenever their drive is connected, even while Nokcandu isn't running:
/// a small login item (launchd agent) that runs whenever any drive mounts.
public enum AutoMount {
    static let label = "io.github.seastwood.nokcandu.gamesvolumes"
    static var listFile: URL { NokPaths.support.appendingPathComponent("games-volumes.txt") }
    static var agentFile: URL { NokPaths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    public static func images() -> [URL] {
        ((try? String(contentsOf: listFile, encoding: .utf8)) ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
    public static func register(_ image: URL) {
        var list = images().map(\.path)
        if !list.contains(image.path) { list.append(image.path) }
        save(list)
    }
    public static func unregister(_ image: URL) {
        save(images().map(\.path).filter { $0 != image.path })
    }
    static func save(_ list: [String]) {
        try? NokPaths.ensure(NokPaths.support)
        try? (list.joined(separator: "\n") + (list.isEmpty ? "" : "\n")).write(to: listFile, atomically: true, encoding: .utf8)
        if list.isEmpty { removeAgent() } else { try? installAgent() }
    }

    static func script() -> String {
        // Reads the list each time; attaches only images that exist (their drive is connected) and aren't open.
        """
        LIST="$HOME/Library/Application Support/Nokcandu/games-volumes.txt"
        [ -f "$LIST" ] || exit 0
        INFO="$(/usr/bin/hdiutil info 2>/dev/null)"
        while IFS= read -r IMG; do
          [ -n "$IMG" ] && [ -d "$IMG" ] || continue
          printf '%s\\n' "$INFO" | /usr/bin/grep -Fq "$IMG" && continue
          /usr/bin/hdiutil attach "$IMG" -noautoopen >/dev/null 2>&1
        done < "$LIST"
        exit 0
        """
    }

    static func installAgent() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", script()],
            "RunAtLoad": true,
            "StartOnMount": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? Data(contentsOf: agentFile)) == data { return }
        try FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentFile, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20)
        _ = try? Shell.run("/bin/launchctl", ["bootstrap", domain, agentFile.path], timeout: 20)
    }
    static func removeAgent() {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        try? FileManager.default.removeItem(at: agentFile)
    }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: agentFile.path) }
}
