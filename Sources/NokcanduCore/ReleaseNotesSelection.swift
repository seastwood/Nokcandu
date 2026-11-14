// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which versions' release notes to show after an update: every version newer than the last one whose notes
/// were seen, up to the one running, newest first. Someone who skips versions used to see only the newest
/// version's notes and never heard of what the versions in between brought (0.13.0's Streams tab, for one).
public enum ReleaseNotesSelection {
    public static let limit = 10
    /// `available`: versions that have notes ("0.13.1"); `seen`: the last version whose notes were shown (nil:
    /// none recorded); `current`: the running version. `more`: whether older missed versions were left out.
    public static func missed(available: [String], seen: String?, current: String, limit: Int = limit) -> (versions: [String], more: Bool) {
        let upToCurrent = available.filter { $0 == current || AppUpdate.isNewer(current, than: $0) }
        guard let seen, !seen.isEmpty, AppUpdate.isNewer(current, than: seen) else {
            return (upToCurrent.contains(current) ? [current] : [], false)       // nothing missed: just this version
        }
        let newer = upToCurrent.filter { AppUpdate.isNewer($0, than: seen) }
            .sorted { AppUpdate.isNewer($0, than: $1) }
        return (Array(newer.prefix(max(1, limit))), newer.count > max(1, limit))
    }
    /// The version in a notes file's name ("v0.13.1.md"), or nil.
    public static func version(fileName: String) -> String? {
        guard fileName.hasPrefix("v"), fileName.hasSuffix(".md") else { return nil }
        let v = String(fileName.dropFirst().dropLast(3))
        return v.isEmpty || !v.first!.isNumber ? nil : v
    }
}
