// SPDX-License-Identifier: GPL-3.0-only
// ~/Library/Logs/Nokcandu/Controllers.log: when a controller connects, pauses, is taken over or let go, and why.
// For troubleshooting controllers that stop responding. Bounded: past 1 MB the log so far becomes
// Controllers.previous.log (replacing the one before).
import Foundation

enum ControllerLog {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nokcandu/Controllers.log")
    private static let queue = DispatchQueue(label: "nokcandu.controllerlog")
    static func add(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async {
            let url = file
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                if (try? h.seekToEnd()) ?? 0 > 1_000_000 {
                    try? h.close()
                    let previous = url.deletingLastPathComponent().appendingPathComponent("Controllers.previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try? FileManager.default.moveItem(at: url, to: previous)
                    try? Data(text.utf8).write(to: url)
                    return
                }
                h.write(Data(text.utf8)); try? h.close()
            } else { try? Data(text.utf8).write(to: url) }
        }
    }
}
