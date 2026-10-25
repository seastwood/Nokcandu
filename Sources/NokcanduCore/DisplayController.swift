import Foundation

/// Milestone 2: switch Zero Hour between the validated desktop-sized fullscreen ("Fill screen")
/// and the 1280 × 800 recovery window ("Windowed").
///
/// The validated fullscreen presentation is three things that must agree:
///   1. the launcher passes `-fullscreen -xres <desktop> -yres <desktop>` (desktop queried every launch),
///   2. GeneralsOnline's launcher.json has `"windowed": false`,
///   3. Options.ini `Resolution` equals the current scaled desktop.
/// Windowed is `-win -xres 1280 -yres 800`, `"windowed": true`, `Resolution = 1280 800`.
///
/// Every edit goes through the ChangeJournal, so "Reset" restores the exact files from before.
public enum LauncherState: Equatable {
    case original          // byte-identical to the validated launcher
    case nokcanduPatched   // validated launcher + Nokcandu's display-mode line
    case unrecognized      // changed by something else: Nokcandu will not edit it
    case missing
}

public struct DisplayStatus: Equatable {
    public var mode: DisplayMode
    public var launcher: LauncherState
    public var launcherJSONWindowed: Bool?
    public var optionsResolution: String?
    public var desktop: DesktopSize
    public var consistent: Bool
}

public enum DisplayController {
    public static let patchMarker = "# nokcandu-display-mode"
    static let originalLine = #"if [ "${1:-}" = --windowed ]; then"#
    static let patchedLines = """
MODE_FILE="$SUPPORT/nokcandu/display-mode" \(patchMarker) (Fill screen unless this file says windowed)
if [ "${1:-}" = --windowed ] || { [ -z "${1:-}" ] && [ "$(cat "$MODE_FILE" 2>/dev/null)" = windowed ]; }; then
"""

    public static var zeroHourDataFolder: URL {
        NokPaths.home.appendingPathComponent("Documents/Command and Conquer Generals Zero Hour Data", isDirectory: true)
    }
    static var optionsURL: URL { zeroHourDataFolder.appendingPathComponent("Options.ini") }
    static var launcherJSONURL: URL { zeroHourDataFolder.appendingPathComponent("GeneralsOnlineData/launcher.json") }
    static func modeFile(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("display-mode") }

    public static func supports(_ g: InstalledGame) -> Bool { g.recipe?.display != nil }

    // MARK: Pure text transforms (unit-tested)

    public static func patchLauncher(_ text: String) -> String? {
        guard text.contains(originalLine), !text.contains(patchMarker) else { return nil }
        return text.replacingOccurrences(of: originalLine, with: patchedLines.trimmingCharacters(in: .newlines))
    }

    public static func setResolution(in ini: String, width: Int, height: Int) -> String {
        let line = "Resolution = \(width) \(height)"
        if let r = ini.range(of: #"(?m)^Resolution\s*=.*$"#, options: .regularExpression) {
            return ini.replacingCharacters(in: r, with: line)
        }
        return ini + (ini.hasSuffix("\n") || ini.isEmpty ? "" : "\n") + line + "\n"
    }

    public static func resolution(in ini: String) -> String? {
        guard let r = ini.range(of: #"(?m)^Resolution\s*=\s*(.*)$"#, options: .regularExpression) else { return nil }
        return ini[r].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func setWindowed(in json: String, _ windowed: Bool) -> String? {
        guard let r = json.range(of: #""windowed"\s*:\s*(true|false)"#, options: .regularExpression) else { return nil }
        return json.replacingCharacters(in: r, with: "\"windowed\": \(windowed)")
    }

    public static func windowedFlag(in json: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["windowed"] as? Bool
    }

    // MARK: State

    public static func launcherState(_ g: InstalledGame) -> LauncherState {
        guard let url = g.launcherURL, let text = try? String(contentsOf: url, encoding: .utf8),
              let sha = try? Hashing.sha256(file: url) else { return .missing }
        if g.recipe?.knownLauncherHashes[sha] != nil { return .original }
        if text.contains(patchMarker) {
            let restored = text.replacingOccurrences(of: patchedLines.trimmingCharacters(in: .newlines), with: originalLine)
            if g.recipe?.knownLauncherHashes[Hashing.sha256(data: Data(restored.utf8))] != nil { return .nokcanduPatched }
        }
        return .unrecognized
    }

    public static func currentMode(_ g: InstalledGame) -> DisplayMode {
        let raw = (try? String(contentsOf: modeFile(g), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap(DisplayMode.init(rawValue:)) ?? g.recipe?.display?.defaultMode ?? .fillScreen
    }

    public static func status(_ g: InstalledGame) -> DisplayStatus {
        let mode = currentMode(g)
        let desktop = DesktopSize.current()
        let json = readTextAllowingCloud(launcherJSONURL)
        let ini = readTextAllowingCloud(optionsURL)
        let windowedFlag = json.flatMap(windowedFlag(in:))
        let res = ini.flatMap(resolution(in:))
        let launcher = launcherState(g)
        let rw = g.recipe?.display?.recoveryWindow ?? DesktopSize(width: 1280, height: 800)
        let wantRes = mode == .windowed ? "\(rw.width) \(rw.height)" : "\(desktop.width) \(desktop.height)"
        var consistent = (windowedFlag == nil || windowedFlag == (mode == .windowed)) && (res == nil || res == wantRes)
        if mode == .windowed && launcher != .nokcanduPatched { consistent = false }
        return DisplayStatus(mode: mode, launcher: launcher, launcherJSONWindowed: windowedFlag,
                             optionsResolution: res, desktop: desktop, consistent: consistent)
    }

    // MARK: Changes

    /// Switch display mode. Reversible: every touched file is journaled.
    @discardableResult
    public static func apply(_ mode: DisplayMode, to g: InstalledGame) throws -> String {
        guard let policy = g.recipe?.display else { throw NokError("Display modes are not validated for \(g.name).") }
        if case .launcherRunning = GameLauncher.runState(of: g) {
            throw NokError("Quit \(g.name) first — settings are read when the game starts.")
        }
        let journal = ChangeJournal(scope: g.journalScope)
        var notes: [String] = []

        // 1. Teach the launcher to honor the setting when opened from Finder/Dock.
        switch launcherState(g) {
        case .original:
            let url = g.launcherURL!
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let patched = patchLauncher(text) else { throw NokError("Launcher layout not recognized; nothing changed.") }
            try journal.write(Data(patched.utf8), to: url, reason: "Launcher reads Nokcandu display setting")
        case .nokcanduPatched:
            break
        case .unrecognized:
            throw NokError("The game's launcher was changed outside Nokcandu, so it won't be edited. Use Diagnostics or restore it first.")
        case .missing:
            throw NokError("The game's launcher is missing.")
        }

        // 2. Persist the choice inside the game app (survives relaunches and Finder launches).
        try journal.write(Data((mode.rawValue + "\n").utf8), to: modeFile(g), reason: "Display mode: \(mode.title)")

        // 3. GeneralsOnline launcher.json
        if let json = readTextAllowingCloud(launcherJSONURL) {
            if let updated = setWindowed(in: json, mode == .windowed) {
                try journal.write(Data(updated.utf8), to: launcherJSONURL, reason: "GeneralsOnline windowed = \(mode == .windowed)")
            } else {
                notes.append("launcher.json has no \"windowed\" setting; left unchanged.")
            }
        } else {
            notes.append("GeneralsOnline settings not created yet; the game will create them.")
        }

        // 4. Options.ini resolution
        try syncOptionsResolution(g, mode: mode, policy: policy, journal: journal)

        let size = mode == .windowed ? policy.recoveryWindow : DesktopSize.current()
        return (["\(mode.title) set (\(size))."] + notes).joined(separator: " ")
    }

    /// Called before each launch from Nokcandu: in Fill screen, match the *current* desktop size.
    public static func prepareForLaunch(_ g: InstalledGame) {
        guard let policy = g.recipe?.display, launcherState(g) == .nokcanduPatched else { return }
        let journal = ChangeJournal(scope: g.journalScope)
        try? syncOptionsResolution(g, mode: currentMode(g), policy: policy, journal: journal)
    }

    static func syncOptionsResolution(_ g: InstalledGame, mode: DisplayMode, policy: DisplayPolicy, journal: ChangeJournal) throws {
        guard let ini = readTextAllowingCloud(optionsURL) else { return }
        let size = mode == .windowed ? policy.recoveryWindow : DesktopSize.current()
        let updated = setResolution(in: ini, width: size.width, height: size.height)
        if updated != ini {
            try journal.write(Data(updated.utf8), to: optionsURL, reason: "Resolution \(size)")
        }
    }

    /// Safe reset: undo every Nokcandu change for this game (launcher, mode file, game settings).
    /// Saves, replays, maps and anything Nokcandu did not write are never touched.
    public static func reset(_ g: InstalledGame) throws -> ChangeJournal.RevertReport {
        if case .launcherRunning = GameLauncher.runState(of: g) {
            throw NokError("Quit \(g.name) before resetting.")
        }
        var report = ChangeJournal(scope: g.journalScope).revertAll()
        // The game rewrites Options.ini itself, so a byte-exact restore can be skipped above.
        // Make sure the two display keys are back on the validated Fill screen values anyway
        // (targeted key edits only — the rest of the user's options are untouched).
        guard g.recipe?.display != nil else { return report }
        let desktop = DesktopSize.current()
        if let ini = readTextAllowingCloud(optionsURL) {
            let fixed = setResolution(in: ini, width: desktop.width, height: desktop.height)
            if fixed != ini, (try? Data(fixed.utf8).write(to: optionsURL, options: .atomic)) != nil {
                report.restored.append(optionsURL.path + " (Resolution only)")
            }
        }
        if let json = readTextAllowingCloud(launcherJSONURL),
           let fixed = setWindowed(in: json, false), fixed != json,
           (try? Data(fixed.utf8).write(to: launcherJSONURL, options: .atomic)) != nil {
            report.restored.append(launcherJSONURL.path + " (windowed only)")
        }
        try? FileManager.default.removeItem(at: modeFile(g))
        if (try? FileManager.default.contentsOfDirectory(atPath: g.nokcanduState.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: g.nokcanduState)
        }
        return report
    }
}
