import Foundation

/// A socket-delivered down must release through the same process, even after
/// focus/capture changes. A failed release never falls back to an absolute click.
public struct PadMouseSocketRoute {
    private var targets: [Int: Int32] = [:]
    public init() {}
    public var held: Set<Int> { Set(targets.keys) }
    public mutating func route(button: Int, down: Bool, target: Int32, available: Bool,
                               send: (Int32, Int, Bool) -> Bool) -> Bool {
        guard (0...4).contains(button) else { return false }
        if let original = targets[button] {
            if !down { _ = send(original, button, false); targets[button] = nil }
            return true
        }
        guard down, target > 0, available, send(target, button, true) else { return false }
        targets[button] = target
        return true
    }
}

/// Where a game's helper keeps its sockets: a folder in /tmp that only this user can enter. /tmp itself is
/// shared by every account on the Mac, so another account could have taken a socket's name there first and
/// received what Nokcandu sends the game. (Application Support would do too, but a socket's path is limited to
/// 103 characters, which a long account name would exceed.)
public enum PadSocketFolder {
    public static func path(uid: UInt32 = getuid()) -> String { "/tmp/nokcandu-\(uid)" }
    /// A real folder (not a link), this user's, closed to everyone else.
    public static func isPrivate(_ path: String, uid: UInt32 = getuid()) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid && (st.st_mode & 0o077) == 0
    }
    /// Where to look for a helper's file named `name`: the private folder, then /tmp itself for a game that
    /// was started by a Nokcandu from before November 14, 2026 and is still running.
    public static func candidates(_ name: String, uid: UInt32 = getuid(), folder: String? = nil) -> [String] {
        let f = folder ?? path(uid: uid)
        return (isPrivate(f, uid: uid) ? [f + "/" + name] : []) + ["/tmp/" + name]
    }
}

/// A game's helper leaves its socket (and its "buttons" note) in /tmp when the game is killed rather than quit.
/// Nothing reads them again — the name carries the dead process's number — so they only pile up.
public enum PadSocketLeftovers {
    /// The files among `names` that belong to this user's helpers whose process is gone.
    public static func stale(_ names: [String], uid: UInt32, alive: (Int32) -> Bool) -> [String] {
        let prefix = "nokcandu-pad-\(uid)-"
        return names.filter { name in
            guard name.hasPrefix(prefix) else { return false }
            let rest = name.dropFirst(prefix.count)
            guard rest.hasSuffix(".sock") || rest.hasSuffix(".sock.buttons"),
                  let pid = Int32(rest.prefix { $0.isNumber }), pid > 1,
                  String(pid) + ".sock" == rest || String(pid) + ".sock.buttons" == rest else { return false }
            return !alive(pid)
        }
    }
    public static func removeAll() { remove(folder: "/tmp"); if PadSocketFolder.isPrivate(PadSocketFolder.path()) { remove(folder: PadSocketFolder.path()) } }
    public static func remove(folder: String = "/tmp") {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        // EPERM means a live process we may not signal: leave its files alone.
        for name in stale(names, uid: getuid(), alive: { kill($0, 0) == 0 || errno == EPERM }) { unlink(folder + "/" + name) }
    }
}
