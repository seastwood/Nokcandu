// SPDX-License-Identifier: GPL-3.0-only
// A troubleshooting record of the Steam Controller pads' movement on its way to the pointer: each report's
// readings, what the pad logic made of them, and which route the movement took (or why it was dropped).
import Foundation

/// Off unless the file ~/Library/Logs/Nokcandu/pad-trace.on exists (checked once a second). Writes
/// ~/Library/Logs/Nokcandu/pad-trace.log, at most `limit` lines in all, then stops until the app starts again.
/// Movement only: no keys, no application names.
@MainActor final class PadTrace {
    static let shared = PadTrace()
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nokcandu")
    private var enabled = false, checked = 0.0, written = 0, buffer: [String] = [], flushed = 0.0
    private let limit = 40_000
    var on: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checked >= 1 {
            checked = now
            enabled = written < limit && FileManager.default.fileExists(atPath: folder.appendingPathComponent("pad-trace.on").path)
            if !enabled, !buffer.isEmpty { flush() }
        }
        return enabled
    }
    func add(_ line: @autoclosure () -> String) {
        guard on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        buffer.append(String(format: "%.6f ", now) + line())
        if now - flushed >= 0.5 || buffer.count >= 2000 { flush() }
    }
    private func flush() {
        flushed = ProcessInfo.processInfo.systemUptime
        guard !buffer.isEmpty else { return }
        written += buffer.count
        let text = buffer.joined(separator: "\n") + "\n"; buffer = []
        let url = folder.appendingPathComponent("pad-trace.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        } else { try? Data(text.utf8).write(to: url) }
    }
}
