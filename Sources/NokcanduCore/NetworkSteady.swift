import Foundation

/// Steadier Wi-Fi while playing. macOS keeps a second wireless link (AWDL, for AirDrop, AirPlay, Sidecar and
/// Universal Control) that makes Wi-Fi hop channels every few seconds — short lag spikes in online games.
/// A small system helper (installed once with an administrator password) switches it off while Nokcandu says a
/// game is running and back on afterwards. It does nothing else, and stops when Nokcandu isn't running.
public enum NetworkSteady {
    public static let label = "io.github.seastwood.nokcandu.network"
    static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    static let script = URL(fileURLWithPath: "/Library/Application Support/Nokcandu/network-steady.sh")
    /// Written by Nokcandu while a game runs: its own process id (the helper checks it's alive).
    public static var flag: URL { NokPaths.support.appendingPathComponent("network-steady-playing") }
    static var offFile: URL { NokPaths.support.appendingPathComponent("network-steady-off") }

    public static var installed: Bool { FileManager.default.fileExists(atPath: daemonPlist.path) && FileManager.default.fileExists(atPath: script.path) }
    /// On unless turned off in Settings (only does anything once the helper is installed).
    public static var enabled: Bool {
        get { !FileManager.default.fileExists(atPath: offFile.path) }
        set {
            if newValue { try? FileManager.default.removeItem(at: offFile) }
            else { try? NokPaths.ensure(NokPaths.support); FileManager.default.createFile(atPath: offFile.path, contents: Data()); setPlaying(false) }
        }
    }

    /// The helper's script. Root runs it; it reads only the flag file and only runs ifconfig on awdl0.
    static func scriptText(flag: String) -> String {
        """
        #!/bin/bash
        # Nokcandu: AWDL off while a game runs (see \(label)). Puts it back when the game stops or Nokcandu quits.
        FLAG=\(shq(flag))
        DOWNED=0
        while true; do
          PID=$(head -1 "$FLAG" 2>/dev/null)
          if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
            if /sbin/ifconfig awdl0 2>/dev/null | grep -q "<UP"; then
              /sbin/ifconfig awdl0 down 2>/dev/null && DOWNED=1
            fi
          elif [ "$DOWNED" = 1 ]; then
            /sbin/ifconfig awdl0 up 2>/dev/null; DOWNED=0
          fi
          sleep 1
        done
        """
    }

    static func plistText() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>/bin/bash</string><string>\(script.path)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
        </dict></plist>
        """
    }

    /// Installs the helper (macOS asks for an administrator password).
    public static func install() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("nokcandu-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let s = work.appendingPathComponent("network-steady.sh"), p = work.appendingPathComponent("\(label).plist")
        try Data(scriptText(flag: flag.path).utf8).write(to: s)
        try Data(plistText().utf8).write(to: p)
        let cmd = [
            "/bin/launchctl bootout system/\(label) 2>/dev/null; true",
            "/bin/mkdir -p \(shq(script.deletingLastPathComponent().path))",
            "/usr/bin/install -o root -g wheel -m 755 \(shq(s.path)) \(shq(script.path))",
            "/usr/bin/install -o root -g wheel -m 644 \(shq(p.path)) \(shq(daemonPlist.path))",
            "/bin/launchctl bootstrap system \(shq(daemonPlist.path))",
        ].joined(separator: " && ")
        try runAsAdmin(cmd, prompt: "Nokcandu wants to install a helper that keeps Wi-Fi steady while you play.")
    }

    /// Removes the helper and turns AWDL back on.
    public static func uninstall() throws {
        let cmd = "/bin/launchctl bootout system/\(label) 2>/dev/null; /bin/rm -f \(shq(daemonPlist.path)) \(shq(script.path)); /sbin/ifconfig awdl0 up 2>/dev/null; true"
        try runAsAdmin(cmd, prompt: "Nokcandu wants to remove its Wi-Fi helper.")
    }

    static func runAsAdmin(_ cmd: String, prompt: String) throws {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let r = try Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with prompt \"\(p)\" with administrator privileges"], timeout: 300)
        guard r.ok else {
            if r.combined.contains("-128") { throw NokError("Cancelled.") }
            throw NokError("The helper couldn't be changed: \(r.combined.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
        }
    }

    /// Called as games start and stop.
    public static func setPlaying(_ playing: Bool) {
        let want = playing && enabled && installed
        let fm = FileManager.default
        if want {
            let text = "\(getpid())\n"
            if (try? String(contentsOf: flag, encoding: .utf8)) != text { try? NokPaths.ensure(NokPaths.support); try? Data(text.utf8).write(to: flag, options: .atomic) }
        } else if fm.fileExists(atPath: flag.path) {
            try? fm.removeItem(at: flag)
        }
    }

    /// Whether AWDL is switched off right now (for Settings).
    public static var awdlOff: Bool {
        guard let r = try? Shell.run("/sbin/ifconfig", ["awdl0"], timeout: 5) else { return false }
        return !r.combined.contains("<UP")
    }
}

private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
