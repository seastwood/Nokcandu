import Foundation

/// Bonjour for Windows games, from the Mac's own Bonjour.
///
/// Nokcandu's helper library relays Windows Bonjour requests (Apple's protocol on 127.0.0.1:5354) to macOS's
/// mDNSResponder, so games find each other on the local network without Windows Bonjour. Some games (Blizzard's)
/// also install their own copy of the Windows "Bonjour Service" and won't use Bonjour unless it starts; under Wine
/// it can't. Its entry is pointed at a small stand-in that starts, reports running and does nothing else.
/// Checked before every launch, so a game reinstalling its own service is put right again.
public enum BonjourService {
    static let exeName = "nokcandu-bonjour-service.exe"
    static let section = #"[System\\ControlSet001\\Services\\Bonjour Service]"#
    static let ourImage = #""ImagePath"="C:\\windows\\system32\\nokcandu-bonjour-service.exe""#

    /// Before a launch: fixes the environment's Bonjour Service entry if a game installed one.
    public static func prepareForLaunch(_ g: InstalledGame) async {
        guard g.native == nil, let h = WineTools.hostContents(for: g) else { return }
        let prefix = h.appendingPathComponent("SharedSupport/prefix")
        if await WineTools.environmentIsRunning(for: g) { fixRunning(contents: h, prefix: prefix) }
        else { _ = try? fix(prefix: prefix) }
    }

    /// The environment is running (a launcher stays open): change the entry through Wine's own registry tool.
    static func fixRunning(contents h: URL, prefix: URL) {
        guard let stub = NokPaths.bundledResource(exeName),
              let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8),
              let r = text.range(of: section) else { return }
        let rest = text[r.upperBound...]
        let body = rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)]
        let fm = FileManager.default
        let exe = prefix.appendingPathComponent("drive_c/windows/system32/\(exeName)")
        if !fm.contentsEqual(atPath: exe.path, andPath: stub.path) {
            try? fm.removeItem(at: exe)
            try? fm.copyItem(at: stub, to: exe)
        }
        guard !body.contains(ourImage) || body.contains(#""WOW64"="#) else { return }
        if let line = body.components(separatedBy: "\n").first(where: { $0.hasPrefix(#""ImagePath"="#) }), line != ourImage {
            try? Data(line.utf8).write(to: prefix.appendingPathComponent(".nokcandu-bonjour-imagepath"), options: .atomic)
        }
        let key = #"HKLM\System\CurrentControlSet\Services\Bonjour Service"#
        for args in [["reg", "add", key, "/v", "ImagePath", "/t", "REG_SZ", "/d", #"C:\windows\system32\nokcandu-bonjour-service.exe"#, "/f"],
                     ["reg", "delete", key, "/v", "WOW64", "/f"]] {
            let p = Process()
            p.executableURL = h.appendingPathComponent("SharedSupport/wine/bin/wine")
            p.arguments = args
            p.environment = WineTools.environment(contents: h)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
        }
    }

    /// Returns true when it changed something. The environment must not be running.
    @discardableResult
    static func fix(prefix: URL, stub: URL? = NokPaths.bundledResource(exeName)) throws -> Bool {
        let reg = prefix.appendingPathComponent("system.reg"), fm = FileManager.default
        guard let stub, let text = try? String(contentsOf: reg, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(section) }) else { return false }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }

        let exe = prefix.appendingPathComponent("drive_c/windows/system32/\(exeName)")
        var changed = false
        if !fm.contentsEqual(atPath: exe.path, andPath: stub.path) {
            try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: exe.path) { try fm.removeItem(at: exe) }
            try fm.copyItem(at: stub, to: exe)
            changed = true
        }
        var body = Array(lines[(start + 1)..<end])
        if let i = body.firstIndex(where: { $0.hasPrefix(#""ImagePath"="#) }), body[i] != ourImage {
            // Keep the game's own entry, so it can be put back.
            let keep = prefix.appendingPathComponent(".nokcandu-bonjour-imagepath")
            try? Data(body[i].utf8).write(to: keep, options: .atomic)
            body[i] = ourImage
            changed = true
        } else if !body.contains(where: { $0.hasPrefix(#""ImagePath"="#) }) {
            body.insert(ourImage, at: 0)
            changed = true
        }
        // The stand-in is a 64-bit program.
        if let i = body.firstIndex(where: { $0.hasPrefix(#""WOW64"="#) }) { body.remove(at: i); changed = true }
        guard changed else { return false }
        lines.replaceSubrange((start + 1)..<end, with: body)
        try Data(lines.joined(separator: "\n").utf8).write(to: reg, options: .atomic)
        return true
    }
}
