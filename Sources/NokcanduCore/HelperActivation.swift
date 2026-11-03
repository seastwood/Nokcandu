import Foundation
import Darwin

public enum HelperActivation: String, Equatable {
    case ready, current, restartRequired, updateRequired, unknown
    public var message: String? {
        switch self {
        case .ready, .current: return nil
        case .restartRequired: return "A helper update is installed but this Windows session is using older or unverified code. Quit this game through Nokcandu and reopen it. For shared games, quit their launcher through Nokcandu too."
        case .updateRequired: return "This game's audio/input helper needs updating. Run Repair while the game and its launcher are closed."
        case .unknown: return "The running helper version could not be checked. No restart or repair has been assumed complete."
        }
    }
    struct Record: Codable { var pid: Int32; var startSeconds: UInt64; var startMicros: UInt64; var build: String; var role: String }
    static func startTime(_ pid: Int32) -> (UInt64, UInt64)? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }
    static func assess(expected: String?, installed: String?, processes: [Int32], records: [Record], reliable: Bool,
                       birth: (Int32) -> (UInt64, UInt64)?) -> HelperActivation {
        guard reliable else { return .unknown }
        guard let expected else { return .unknown }
        guard installed == expected else { return .updateRequired }
        if processes.isEmpty { return .ready }
        for pid in processes {
            guard let record = records.first(where: { $0.pid == pid }), let start = birth(pid),
                  start.0 == record.startSeconds, start.1 == record.startMicros, record.build == expected else { return .restartRequired }
        }
        return .current
    }
    public static func statuses(for games: [InstalledGame]) -> [InstalledGame.ID: HelperActivation] {
        let snapshot = GameLauncher.processStatus()
        let expectedSHA = RawMouse.bundledLibrary.flatMap { try? Hashing.sha256(file: $0) }
        var hosts: [URL: HelperActivation] = [:], result: [InstalledGame.ID: HelperActivation] = [:]
        for game in games where game.native == nil {
            guard let host = WineTools.hostContents(for: game) else { continue }
            if hosts[host] == nil {
                let folder = host.appendingPathComponent("SharedSupport/nokcandu")
                let directory = folder.appendingPathComponent("loaded-helpers")
                var records: [Record] = []
                for file in (directory.resolvingSymlinksInPath() == directory ? (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) : nil) ?? [] {
                    guard file.resolvingSymlinksInPath() == file, file.pathExtension == "json", let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data), record.pid > 1, file.lastPathComponent == "\(record.pid).json" else { continue }
                    if let start = startTime(record.pid), start.0 == record.startSeconds, start.1 == record.startMicros { records.append(record) }
                    else if snapshot.reliable { try? FileManager.default.removeItem(at: file) }
                }
                let pids = snapshot.rows.map(\.0).filter { WineTools.owns(pid: $0, contents: host) }
                var installed = (try? String(contentsOf: folder.appendingPathComponent("helper-build.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                if expectedSHA == nil || (try? Hashing.sha256(file: folder.appendingPathComponent(RawMouse.dylibName))) != expectedSHA { installed = nil }
                hosts[host] = assess(expected: RawMouse.bundledBuildID, installed: installed, processes: pids, records: records, reliable: snapshot.reliable, birth: startTime)
            }
            result[game.id] = hosts[host]
        }
        return result
    }
}
