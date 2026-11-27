// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Nokcandu's own crash reports from macOS (~/Library/Logs/DiagnosticReports/Nokcandu-….ips): at launch, the ones
/// newer than the last launch's check, so Nokcandu can say it quit unexpectedly and where the report is.
public enum NokcanduCrashReports {
    public static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports") }
    public static let checkedKey = "crashReportsCheckedThrough"

    /// Reports in `folder` named for Nokcandu and modified after `since`, newest first.
    public static func new(in folder: URL = folder, since: Date) -> [(url: URL, date: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("Nokcandu-"), name.hasSuffix(".ips") || name.hasSuffix(".crash"),
                  let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date > since else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.map { (url: $0.0, date: $0.1) }
    }

    /// Checks once a launch: the newest report since the last check (nil if none), and records this check.
    /// The first launch with this check only records it.
    public static func checkAtLaunch(defaults: UserDefaults = .standard, folder: URL = folder, now: Date = Date()) -> (url: URL, date: Date, count: Int)? {
        let last = defaults.object(forKey: checkedKey) as? Date
        defaults.set(now, forKey: checkedKey)
        guard let last else { return nil }
        let found = new(in: folder, since: last)
        return found.first.map { ($0.url, $0.date, found.count) }
    }
}
