import Foundation

/// Adds Nokcandu's helper library (Dock names, Game Mode, raw mouse) to the tested launchers of built-in
/// recipes (Zero Hour, Worms), which predate it. The launchers are recognised by their fingerprint, so the
/// addition is a marked block that `strip` removes before fingerprinting — the launcher still counts as the
/// tested original. Written through the change journal, so it can be undone.
public enum HelperPatch {
    public static let marker = "# nokcandu-helper-library"

    static let legacyBlock = """
    \(marker) (added by Nokcandu: real app names, Game Mode, raw mouse)
    if [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ]; then
     export DYLD_INSERT_LIBRARIES="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib"
     export NOKCANDU_APP_NAMES="$SUPPORT/nokcandu/app-names.tsv"
     if [ -f "$SUPPORT/nokcandu/raw-mouse" ]; then
      export NOKCANDU_RAW_MOUSE_SCALE="$(head -n 1 "$SUPPORT/nokcandu/raw-mouse")"
      [ -f "$SUPPORT/nokcandu/raw-mouse-debug" ] && export NOKCANDU_RAW_MOUSE_DEBUG=1
      [ "$(/usr/bin/sed -n 2p "$SUPPORT/nokcandu/raw-mouse")" = smooth ] && export NOKCANDU_RAW_MOUSE_SMOOTH=1
     fi
    fi
    \(marker) end

    """

    static let globalExport = #"export DYLD_INSERT_LIBRARIES="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib""#
    static let scopedPrefix = #"DYLD_INSERT_LIBRARIES="${NOKCANDU_HELPER_LIBRARY:-}" "#
    static let block = legacyBlock.replacingOccurrences(of: globalExport,
        with: #"NOKCANDU_HELPER_LIBRARY="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib""#)

    /// Keep the Intel Wine helper out of native utilities (Python, display tools, store helpers).
    /// Shared by built-in recipes, general game launchers and the shared Steam helper.
    static func scopeWineLibrary(_ text: String) -> String {
        var result = text.replacingOccurrences(of: globalExport,
            with: #"NOKCANDU_HELPER_LIBRARY="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib""#)
        result = result.components(separatedBy: "\n").map { line in
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            let command = body.hasPrefix("exec ") ? body.dropFirst(5) : body
            guard command.hasPrefix(#""$SUPPORT/wine/bin/wine" "#) || command.hasPrefix(#""$WINE" "#) else { return line }
            return String(line.prefix(line.count - body.count)) + scopedPrefix + body
        }.joined(separator: "\n")
        // Wine's child-process registry still needs the helper path. This is a non-exported
        // shell variable inside a command substitution containing only shell builtins.
        return result.replacingOccurrences(of: #"WANT="$(for v in DYLD_INSERT_LIBRARIES"#,
            with: #"WANT="$(DYLD_INSERT_LIBRARIES="${NOKCANDU_HELPER_LIBRARY:-}"; for v in DYLD_INSERT_LIBRARIES"#)
    }

    /// Adds or upgrades the recognised helper block. Already-current launchers are unchanged.
    public static func add(to text: String) -> String? {
        let original = strip(text)
        guard !original.contains(marker) else { return nil }
        var lines = original.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("export PATH=") }) else { return nil }
        lines.insert(contentsOf: block.components(separatedBy: "\n").dropLast(), at: i + 1)
        let patched = scopeWineLibrary(lines.joined(separator: "\n"))
        return patched == text ? nil : patched
    }

    /// Both helper versions normalise to the exact tested launcher for fingerprint checks.
    public static func strip(_ text: String) -> String {
        if text.contains(block) {
            return text.replacingOccurrences(of: block, with: "").components(separatedBy: "\n").map { line in
                let body = line.drop(while: { $0 == " " || $0 == "\t" })
                guard body.hasPrefix(scopedPrefix) else { return line }
                return String(line.prefix(line.count - body.count)) + body.dropFirst(scopedPrefix.count)
            }.joined(separator: "\n")
        }
        return text.replacingOccurrences(of: legacyBlock, with: "")
    }

    /// Upgrade recognised recipe launchers and hash-verified generated launchers. Native tools
    /// stay outside Wine's injection environment. Running games and manual launcher edits stay intact.
    @discardableResult
    public static func refresh(_ games: [InstalledGame]) -> [String] {
        var changed: [String] = []
        for g in games {
            guard let url = g.launcherURL, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if case .launcherRunning = GameLauncher.runState(of: g) { continue }
            CompatibilityFixes.refreshBundledHelpers(g)
            if let config = g.custom {
                guard config.launcherSHA == Hashing.sha256(data: Data(text.utf8)), CustomGames.launcherScript(for: config) != text else { continue }
                do { try CustomGames.save(config, to: g); changed.append(g.name) } catch { continue }
                continue
            }
            guard g.recipe != nil else { continue }
            switch DisplayController.launcherState(g) {
            case .original, .nokcanduPatched: break
            default: continue
            }
            guard let patched = add(to: text) else { continue }
            do {
                try ChangeJournal(scope: g.journalScope).write(Data(patched.utf8), to: url, reason: "Launcher loads Nokcandu's helper library")
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                changed.append(g.name)
            } catch { continue }
        }
        return changed
    }
}
