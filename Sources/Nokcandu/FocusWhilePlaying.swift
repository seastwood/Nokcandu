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
    static let startName = "Nokcandu Playing", stopName = "Nokcandu Stopped Playing"
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

    private static func run(_ name: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
