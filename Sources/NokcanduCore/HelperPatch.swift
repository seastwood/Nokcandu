import Foundation

/// Adds Nokcandu's helper library (Dock names, Game Mode, raw mouse) to the tested launchers of built-in
/// recipes (Zero Hour, Worms), which predate it. The launchers are recognised by their fingerprint, so the
/// addition is a marked block that `strip` removes before fingerprinting — the launcher still counts as the
/// tested original. Written through the change journal, so it can be undone.
public enum HelperPatch {
    public static let marker = "# nokcandu-helper-library"

    static let block = """
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

    /// The launcher with the block added after its `export PATH=` line; nil if it already has it or has no such line.
    public static func add(to text: String) -> String? {
        guard !text.contains(marker) else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("export PATH=") }) else { return nil }
        lines.insert(contentsOf: block.components(separatedBy: "\n").dropLast(), at: i + 1)
        return lines.joined(separator: "\n")
    }

    /// The launcher without the block (exactly as it was before `add`).
    public static func strip(_ text: String) -> String {
        guard text.contains(marker) else { return text }
        return text.replacingOccurrences(of: block, with: "")
    }

    /// Adds the block to recipe games' launchers that are the tested original (possibly display-patched).
    /// Skips running games. Returns the names of the games it changed.
    @discardableResult
    public static func refresh(_ games: [InstalledGame]) -> [String] {
        var changed: [String] = []
        for g in games where g.recipe != nil && g.custom == nil {
            guard let url = g.launcherURL, let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.contains(marker) else { continue }
            switch DisplayController.launcherState(g) {
            case .original, .nokcanduPatched: break
            default: continue
            }
            if case .launcherRunning = GameLauncher.runState(of: g) { continue }
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
