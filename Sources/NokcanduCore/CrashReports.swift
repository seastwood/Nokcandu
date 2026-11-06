import Foundation

/// Windows programs that crash under Wine get a report from Wine's debugger (registers, the module it crashed
/// in, loaded modules). Wine normally shows it in a dialog only, and it's gone when that closes. Nokcandu has the
/// debugger write it into the Windows environment instead (`C:\nokcandu\crash-report.txt`) and explains it in
/// plain words on the game's page, with the full report one click away.
public enum CrashReports {
    static let windowsPath = #"C:\nokcandu\crash-report.txt"#
    static let defaultDebugger = "winedbg --auto %ld %ld"
    static var debugger: String {
        #"C:\windows\system32\cmd.exe /c C:\windows\system32\winedbg.exe --auto %ld %ld > "# + windowsPath + " 2>&1"
    }
    static let debuggerKeys = [#"Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"#,
                               #"Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"#]
    static let crashDialogKey = #"Software\\Wine\\WineDbg"#

    public static func reportURL(prefix: URL) -> URL { prefix.appendingPathComponent("drive_c/nokcandu/crash-report.txt") }

    /// Sets up report capture in a Windows environment. Only while it's closed (Wine rewrites its registry files
    /// while running), only over Wine's own default or Nokcandu's earlier value (a debugger chosen by hand stays).
    /// Returns true when something changed.
    @discardableResult
    public static func ensureCapture(contents: URL) -> Bool {
        let prefix = contents.appendingPathComponent("SharedSupport/prefix")
        let system = prefix.appendingPathComponent("system.reg"), user = prefix.appendingPathComponent("user.reg")
        guard FileManager.default.fileExists(atPath: system.path), FileManager.default.fileExists(atPath: user.path),
              WineTools.ownedProcesses(contents: contents).isEmpty else { return false }
        var changed = false
        do {
            try NokPaths.ensure(prefix.appendingPathComponent("drive_c/nokcandu"))
            for key in debuggerKeys {
                changed = try RegistryText.set(system, key: key, name: "Debugger", value: RegistryText.string(debugger)) { current in
                    guard let current else { return true }
                    let plain = current.lowercased()
                    return plain.contains("winedbg") && (plain.hasPrefix("winedbg") || plain.contains("crash-report.txt"))
                } || changed
            }
            changed = try RegistryText.set(user, key: crashDialogKey, name: "ShowCrashDialog", value: "dword:00000000") { _ in true } || changed
        } catch { return changed }
        return changed
    }

    /// What a crash report says, in words.
    public struct Explanation: Equatable, Sendable {
        public var title: String
        public var detail: String
        /// The program that crashed and where (e.g. "BF1942.exe, in bf1942 +0x46314").
        public var evidence: String
        public var report: String
        public var date: Date
        /// A mod that's missing pieces, when that's the likely cause.
        public var missingMod: ModDependencies.Missing?
    }

    // MARK: History

    /// Each Windows environment keeps its last reports (Wine writes one file per crash, so a newer crash would
    /// replace an older one): SharedSupport/nokcandu/crashes/<time>.txt, newest 12.
    static func historyFolder(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/crashes", isDirectory: true) }
    static let keepReports = 12
    private static let archived = LockedCache<String, Date>(limit: 256)

    /// Copies the environment's current report into its history, once. Cheap when nothing changed (one stat).
    public static func archive(contents: URL) {
        let url = reportURL(prefix: contents.appendingPathComponent("SharedSupport/prefix"))
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              archived[contents.path] != date else { return }
        archived[contents.path] = date
        let folder = historyFolder(contents)
        let name = String(format: "%.0f.txt", date.timeIntervalSince1970)
        let target = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path),
              let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 4_000_000,
              Report(String(decoding: data, as: UTF8.self)) != nil else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        let old = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted(by: >).dropFirst(keepReports)
        for f in old { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
    }

    /// This game's crashes, newest first (its archived reports plus the current one).
    public static func history(_ g: InstalledGame) -> [Explanation] {
        guard let contents = WineTools.hostContents(for: g) else { return [] }
        archive(contents: contents)
        let folder = historyFolder(contents)
        let mods = ModDependencies.missing(g)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted(by: >)
            .compactMap { name -> Explanation? in
                guard let seconds = Double(name.dropLast(4)),
                      let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                guard let parsed = Report(text), belongs(parsed, to: g) else { return nil }
                return explain(parsed, text: text, date: Date(timeIntervalSince1970: seconds), mods: mods, arguments: g.custom?.arguments ?? "")
            }
    }

    /// "Crashed 3 times in the last week", when it's more than once.
    public static func pattern(_ history: [Explanation], now: Date = Date()) -> String? {
        let week = history.filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
        guard week.count > 1 else { return nil }
        let same = Set(week.map(\.title)).count == 1
        return "Crashed \(week.count) times in the last week" + (same ? ", the same way each time." : ".")
    }

    static func belongs(_ parsed: Report, to g: InstalledGame) -> Bool {
        // In a shared launcher's environment, only crashes of this game's own program belong to it.
        guard g.usesSharedSteam || g.battleNet != nil || g.hosted != nil else { return true }
        guard let program = CompatibilityFixes.programForFixes(g)?.lastPathComponent.lowercased() else { return false }
        return parsed.process?.lowercased().hasSuffix(program) == true
    }

    /// The newest report for this game since `since` (default: any), explained.
    public static func lastCrash(_ g: InstalledGame, since: Date? = nil) -> Explanation? {
        guard let contents = WineTools.hostContents(for: g) else { return nil }
        let url = reportURL(prefix: contents.appendingPathComponent("SharedSupport/prefix"))
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           since.map({ date >= $0 }) ?? true,
           let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 4_000_000 {
            let text = String(decoding: data, as: UTF8.self)
            if let parsed = Report(text), belongs(parsed, to: g) {
                archive(contents: contents)
                return explain(parsed, text: text, date: date, mods: ModDependencies.missing(g), arguments: g.custom?.arguments ?? "")
            }
        }
        // The newest report has no crash in it (the debugger couldn't attach) or is another program's in a shared
        // launcher: this game's newest kept report still counts.
        return history(g).first { r in since.map { r.date >= $0 } ?? true }
    }

    /// The parts of a winedbg report that matter.
    struct Report: Equatable {
        var kind: String            // "page fault on read access to 0x00000004"
        var address: UInt64?        // the address read or written, for page faults
        var module: String?         // module that crashed ("bf1942", "d3d9")
        var process: String?        // "C:\Games\...\BF1942.exe"
        var commandLine: String?    // "BF1942.exe +game FHSW +restart 1"
        var bits: String?           // "32-bit" / "64-bit"

        init?(_ text: String) {
            let lines = text.components(separatedBy: .newlines)
            guard let first = lines.first(where: { $0.hasPrefix("Unhandled exception:") }) else { return nil }
            var k = String(first.dropFirst("Unhandled exception:".count)).trimmingCharacters(in: .whitespaces)
            if let r = k.range(of: " in ") {
                let tail = k[r.upperBound...]
                if tail.contains("32-bit") { bits = "32-bit" } else if tail.contains("64-bit") { bits = "64-bit" }
                k = String(k[..<r.lowerBound])
            }
            kind = k.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let r = kind.range(of: "access to 0x") {
                address = UInt64(kind[r.upperBound...].prefix(while: { $0.isHexDigit }), radix: 16)
            }
            // "=>0 0x00446314 in bf1942 (+0x46314) (0x00000016)" or "=>0 0x... WinMain+0x24(...) [...] in crash (0x...)"
            if let top = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("=>0") }),
               let r = top.range(of: " in ", options: .backwards) {
                module = top[r.upperBound...].split(separator: " ").first.map(String.init)
            }
            // The thread list marks the crashing process with "(D)", followed by its command line in brackets.
            if let i = lines.firstIndex(where: { $0.contains("(D) ") }) {
                process = lines[i].components(separatedBy: "(D) ").last?.trimmingCharacters(in: .whitespaces)
                if i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("["), next.hasSuffix("]") { commandLine = String(next.dropFirst().dropLast()) }
                }
            }
        }
    }

    static let graphicsModules: Set<String> = ["d3d8", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12", "dxgi", "wined3d", "ddraw",
                                                 "opengl32", "winevulkan", "vulkan-1", "d3dimm", "d3dx9_43", "dxvk_d3d9", "libmoltenvk"]
    static let soundModules: Set<String> = ["dsound", "winmm", "mmdevapi", "xaudio2_7", "xaudio2_8", "xaudio2_9", "winecoreaudio",
                                              "dmusic", "dmsynth", "openal32", "fmod", "fmodex", "mss32", "binkawin"]
    static let videoModules: Set<String> = ["binkw32", "binkw64", "quartz", "mfplat", "mf", "winegstreamer", "wmvcore"]

    static func explain(_ r: Report, text: String, date: Date, mods: [ModDependencies.Missing], arguments: String) -> Explanation {
        let module = (r.module ?? "").lowercased()
        let program = r.process.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent } ?? "The game"
        let evidence = program + (r.module.map { ", in \($0)" } ?? "") + " — " + r.kind
        let ownCode = !module.isEmpty && program.lowercased().hasPrefix(module)
        let nearNull = (r.address ?? .max) < 0x10000

        // The mod being loaded (from the crashed command line, else the launch options) is missing pieces.
        let launched = (r.commandLine.flatMap(ModDependencies.launchedMod) ?? ModDependencies.launchedMod(arguments: arguments))?.lowercased()
        if let m = mods.first(where: { $0.mod.lowercased() == launched }) ?? (ownCode && nearNull && mods.count == 1 ? mods.first : nil) {
            return Explanation(title: "\(m.mod) is missing a mod it needs", detail: m.message, evidence: evidence, report: text, date: date, missingMod: m)
        }
        func make(_ title: String, _ detail: String) -> Explanation {
            Explanation(title: title, detail: detail, evidence: evidence, report: text, date: date, missingMod: nil)
        }
        if graphicsModules.contains(module) {
            return make("\(program) crashed in its graphics", "It crashed inside \(r.module ?? "the graphics library"). Try another graphics mode in Display, or a graphics fix in Wine & Fixes (DirectX 9 extras, d3d8to9 for DirectX 8 games).")
        }
        if soundModules.contains(module) {
            return make("\(program) crashed in its sound", "It crashed inside \(r.module ?? "the sound library"). A larger audio buffer (Performance) or the game's own software-sound setting often avoids this.")
        }
        if videoModules.contains(module) {
            return make("\(program) crashed playing a video", "It crashed inside \(r.module ?? "the video library"), which plays the game's videos. The Video and music playback fix in Wine & Fixes, or skipping intro videos in the game's options, usually helps.")
        }
        if r.kind.lowercased().contains("stack overflow") {
            return make("\(program) ran out of stack", "The program called itself until it ran out of room. This is usually a game bug triggered by a setting or a mod; try the game's default settings.")
        }
        if ownCode && nearNull {
            return make("\(program) tried to use something that isn't there",
                        "The game read data it expected to have loaded (a file, a mod's content, a setting). Common causes: a mod or patch missing files, a game version a mod doesn't support, or a corrupted settings file. Try without mods, or reinstall the mod and anything it builds on.")
        }
        if r.kind.lowercased().contains("illegal instruction") || r.kind.lowercased().contains("privileged instruction") {
            return make("\(program) used an instruction this Mac can't run", "Some copy protection and very old programs use instructions that don't run here. A no-CD/updated executable from the publisher's patches usually avoids it.")
        }
        return make("\(program) crashed", "It crashed inside \(r.module ?? "an unknown module") (\(r.kind)). The full report below helps when reporting the problem.")
    }
}

/// Minimal editing of Wine's registry files (system.reg, user.reg) while the environment is closed.
enum RegistryText {
    static func string(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func unquote(_ raw: String) -> String? {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return nil }
        return WineRegistry.decode(String(raw.dropFirst().dropLast()))
    }

    /// Removes `name` under `key`, if present. Returns true when something changed.
    static func remove(_ file: URL, key: String, name: String) throws -> Bool {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        let header = "[" + key.lowercased() + "]"
        let valuePrefix = "\"" + name.lowercased() + "\"="
        guard let h = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { return false }
        var end = h + 1
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        guard let v = (h + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(valuePrefix) }) else { return false }
        lines.remove(at: v)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).nokcandu")
        try Data(lines.joined(separator: "\n").utf8).write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        return true
    }

    /// Sets `name` under `key` (written with doubled backslashes, as in the file). `allow` sees the current string
    /// value (nil when absent) and decides whether to replace it. Preserves everything else in the file.
    static func set(_ file: URL, key: String, name: String, value: String, allow: (String?) -> Bool) throws -> Bool {
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        let header = "[" + key.lowercased() + "]"
        let valuePrefix = "\"" + name.lowercased() + "\"="
        let line = "\"\(name)\"=\(value)"
        if let h = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) {
            var end = h + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            if let v = (h + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(valuePrefix) }) {
                let current = String(lines[v].dropFirst(valuePrefix.count))
                if current == value { return false }
                guard allow(unquote(current) ?? current) else { return false }
                lines[v] = line
            } else {
                guard allow(nil) else { return false }
                var at = h + 1
                if at < end, lines[at].hasPrefix("#time=") { at += 1 }
                lines.insert(line, at: at)
            }
        } else {
            guard allow(nil) else { return false }
            if lines.last == "" { lines.removeLast() }
            lines += ["", "[\(key)] \(Int(Date().timeIntervalSince1970))", line, ""]
        }
        let out = lines.joined(separator: "\n")
        guard out != text else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).nokcandu")
        try Data(out.utf8).write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        return true
    }
}
