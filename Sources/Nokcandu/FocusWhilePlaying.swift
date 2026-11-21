import AppKit
import NokcanduCore

/// Other apps' notifications while playing: macOS lets no app turn a Focus on, but Shortcuts can ("Set Focus").
/// With this on, Nokcandu runs the user's shortcut "Nokcandu Playing" when a game or stream comes to the front and
/// "Nokcandu Stopped Playing" when it leaves, each through /usr/bin/shortcuts. The Gaming Focus's own automatic switch
/// only follows controllers macOS knows, not a Steam Controller.
@MainActor
final class FocusWhilePlaying {
    static let shared = FocusWhilePlaying()
    static let key = "focusShortcutsWhilePlaying"
    nonisolated static let startName = "Nokcandu Playing", stopName = "Nokcandu Stopped Playing"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private var on = false
    private var pending: DispatchWorkItem?

    /// Called whenever what's in front is looked at again. Waits a second, so switching between a game's windows
    /// or a quick look at another app doesn't flip the Focus back and forth.
    func playing(_ playing: Bool) {
        guard Self.enabled || on else { return }
        let want = playing && Self.enabled
        pending?.cancel(); pending = nil
        guard want != on else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, want != self.on else { return }
            self.on = want
            Self.run(want ? Self.startName : Self.stopName)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The names of the user's shortcuts (to say which of the two are missing).
    static func installedNames() async -> Set<String> {
        await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return Set<String>() }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        }.value
    }

    /// Makes the missing shortcuts and hands them to Shortcuts, which asks to add each one (“Add Shortcut”): apps
    /// can't add shortcuts by themselves. Each is one “Set Focus” action, Do Not Disturb on or off; shortcut files must be
    /// signed to be imported, which /usr/bin/shortcuts does. Returns what went wrong, if anything.
    static func addShortcuts(missing: [String]) async -> String? {
        await Task.detached { () -> String? in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nokcandu-focus-shortcuts-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var made: [URL] = []
            for name in missing {
                let plain = folder.appendingPathComponent("plain-\(name == startName ? "on" : "off").shortcut")
                let signed = folder.appendingPathComponent("\(name).shortcut")
                guard let data = try? PropertyListSerialization.data(fromPropertyList: workflow(on: name == startName), format: .binary, options: 0),
                      (try? data.write(to: plain)) != nil else { return "Couldn't write the shortcut files." }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["sign", "--mode", "anyone", "--input", plain.path, "--output", signed.path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "Shortcuts couldn't sign them." }
                p.waitUntilExit()
                guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else { return "Shortcuts couldn't sign them (it needs an internet connection)." }
                made.append(signed)
            }
            for url in made { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
            return nil
        }.value
    }

    nonisolated static func workflow(on: Bool) -> [String: Any] {
        [
            "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": on ? 4292093695 : 255, "WFWorkflowIconGlyphNumber": 61440],
            "WFWorkflowImportQuestions": [Any](), "WFWorkflowTypes": [Any](), "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](), "WFWorkflowHasOutputFallback": false, "WFQuickActionSurfaces": [Any](),
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                // Do Not Disturb: every Mac has it (a Gaming Focus exists only once it's been set up in System Settings).
                "WFWorkflowActionParameters": ["Enabled": on ? 1 : 0] as [String: Any],
            ]],
        ]
    }

    /// Why the last shortcut failed (shown in Settings); nil once one runs.
    static let problemKey = "focusShortcutsProblem"
    static var problem: String? { UserDefaults.standard.string(forKey: problemKey) }

    private static func run(_ name: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
        let err = Pipe(); p.standardOutput = FileHandle.nullDevice; p.standardError = err
        p.terminationHandler = { p in
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Error: ", with: "")
            let failed = p.terminationStatus != 0
            DispatchQueue.main.async {
                if failed { UserDefaults.standard.set("“\(name)” didn't run: \(text.isEmpty ? "Shortcuts reported an error." : text)", forKey: problemKey) }
                else { UserDefaults.standard.removeObject(forKey: problemKey) }
            }
        }
        try? p.run()
    }
}
