// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The settings a host fixes when it starts an app for a stream. Resuming an app that is still running keeps
/// them as they were (seen November 19: a session started in limited range stayed limited until End and Quit App).
public struct StreamLaunchSignature: Codable, Equatable, Sendable {
    public var width: Int?, height: Int?, fps: Int
    public var hdr: Bool, yuv444: Bool, fullRange: Bool
    public var codec: String, channels: String, playOnHost: Bool, optimizeGameSettings: Bool

    public init(_ p: StreamProfile) {
        width = p.video.width; height = p.video.height; fps = p.video.fps
        hdr = p.video.hdr; yuv444 = p.video.yuv444; fullRange = p.video.fullRange
        codec = p.video.codec.rawValue; channels = "\(p.audio.channels)"; playOnHost = p.audio.playOnHost
        optimizeGameSettings = p.optimizeGameSettings
    }

    /// What differs, by the names the stream profile's page shows.
    public func differences(from o: StreamLaunchSignature) -> [String] {
        var d: [String] = []
        if width != o.width || height != o.height { d.append("resolution") }
        if fps != o.fps { d.append("frame rate") }
        if codec != o.codec { d.append("codec") }
        if hdr != o.hdr { d.append("HDR") }
        if yuv444 != o.yuv444 { d.append("full colour (4:4:4)") }
        if fullRange != o.fullRange { d.append("full-range colour") }
        if channels != o.channels { d.append("sound channels") }
        if playOnHost != o.playOnHost { d.append("also play on the host") }
        if optimizeGameSettings != o.optimizeGameSettings { d.append("optimize game settings") }
        return d
    }
}

/// Which app each host last started for this Mac, and with what settings (one small entry per host).
public enum StreamLaunchMemory {
    public struct Entry: Codable, Equatable, Sendable {
        public var appID: Int
        public var signature: StreamLaunchSignature
        public init(appID: Int, signature: StreamLaunchSignature) { self.appID = appID; self.signature = signature }
    }
    static let key = "StreamLaunches"

    public static func last(_ hostID: String, defaults: UserDefaults = .standard) -> Entry? { all(defaults)[hostID] }

    public static func record(_ hostID: String, _ entry: Entry, defaults: UserDefaults = .standard) {
        var a = all(defaults); a[hostID] = entry; save(a, defaults)
    }

    public static func forget(_ hostID: String, defaults: UserDefaults = .standard) {
        var a = all(defaults); guard a.removeValue(forKey: hostID) != nil else { return }; save(a, defaults)
    }

    private static func all(_ d: UserDefaults) -> [String: Entry] {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    private static func save(_ a: [String: Entry], _ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(a) { d.set(data, forKey: key) }
    }
}
