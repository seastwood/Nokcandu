import Foundation

/// Audio buffer size for an app's Wine engine. Wine's Mac audio driver tells games to work in 10 ms chunks
/// and Wine then gives them a buffer of 3 chunks (30 ms) — so any moment the game's audio thread is late by
/// more than 30 ms (busy CPU, translated Intel code) is heard as static or crackling. A larger chunk gives
/// a proportionally larger buffer (20 ms → 60 ms, 40 ms → 120 ms) at the cost of a little sound delay.
///
/// The value lives as two constants in the engine's audio driver (winecoreaudio.so: default and minimum
/// device period, in 100 ns units). Nokcandu changes only that app's copy (an APFS clone, so other apps are
/// untouched), keeps the original next to it, re-signs it, and checks the exact instruction pattern first.
public enum AudioBuffer {
    public static let choices = [10, 20, 40]          // ms

    static func driver(_ host: URL) -> URL {
        host.appendingPathComponent("SharedSupport/wine/lib/wine/x86_64-unix/winecoreaudio.so")
    }
    static func original(_ host: URL) -> URL {
        host.appendingPathComponent("SharedSupport/nokcandu/winecoreaudio.so.original")
    }

    /// Offsets of the 32-bit immediates in `mov qword ptr [reg], imm32` (48 C7 0r imm32) for a value.
    static func immediates(_ d: Data, value: UInt32) -> [Int] {
        let bytes = [UInt8](d)
        let v = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        var out: [Int] = []
        var i = 0
        while i + 7 <= bytes.count {
            if bytes[i] == 0x48, bytes[i + 1] == 0xC7, bytes[i + 2] <= 0x07, Array(bytes[i + 3..<i + 7]) == v { out.append(i + 3) }
            i += 1
        }
        return out
    }

    /// Current chunk size in ms (nil = this engine's driver isn't the expected kind).
    public static func current(for g: InstalledGame) -> Int? {
        guard let h = WineTools.hostContents(for: g), let d = try? Data(contentsOf: driver(h)) else { return nil }
        return current(driver: d, original: try? Data(contentsOf: original(h)))
    }

    /// Reads the default-period value at the exact spots the original has 10 ms (the minimum of a larger
    /// setting can equal a smaller setting's default, so searching by value alone is ambiguous).
    static func current(driver d: Data, original o: Data?) -> Int? {
        guard let o else { return immediates(d, value: 100_000).count == 2 ? 10 : nil }
        let spots = immediates(o, value: 100_000)
        guard spots.count == 2, let last = spots.max(), last + 4 <= d.count else { return nil }   // re-signing changes the file size, not the code
        let b = [UInt8](d)
        let values = spots.map { at in UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
        guard values[0] == values[1], values[0] % 10_000 == 0 else { return nil }
        return choices.first { $0 * 10_000 == Int(values[0]) }
    }

    /// `movabs rax, 'auou' | 'def '<<32` — the AudioComponentDescription Wine looks up for every stream:
    /// the *default output* unit. On current macOS that unit refuses input (-10879), so microphones never
    /// open. The general-purpose HAL unit ('ahal') plays and records; Wine already picks the device itself.
    static let defaultOutputLookup: [UInt8] = [0x48, 0xB8, 0x75, 0x6F, 0x75, 0x61, 0x20, 0x66, 0x65, 0x64]
    static let halLookup: [UInt8] = [0x48, 0xB8, 0x75, 0x6F, 0x75, 0x61, 0x6C, 0x61, 0x68, 0x61]

    static func offsets(of pattern: [UInt8], in b: [UInt8]) -> [Int] {
        guard b.count >= pattern.count else { return [] }
        return (0...(b.count - pattern.count)).filter { i in pattern.indices.allSatisfy { b[i + $0] == pattern[$0] } }
    }

    /// The engine's driver with the microphone fix and (if not 10 ms) a larger buffer.
    static func adjusted(_ original: Data, ms: Int) throws -> Data {
        var bytes = [UInt8](original)
        let def = immediates(original, value: 100_000), minimum = immediates(original, value: 50_000)
        guard def.count == 2, minimum.count == 2 else { throw NokError("This engine's audio driver isn't the version Nokcandu knows how to adjust; nothing was changed.") }
        func put(_ at: Int, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { for (k, b) in $0.enumerated() { bytes[at + k] = b } } }
        for at in def { put(at, UInt32(ms * 10_000)) }
        for at in minimum { put(at, UInt32(ms * 5_000)) }
        for at in offsets(of: defaultOutputLookup, in: bytes) { for (k, b) in halLookup.enumerated() { bytes[at + k] = b } }
        return Data(bytes)
    }

    public enum DriverStatus: Equatable { case fixed, needsFix, unrecognized, missing }

    /// Whether Nokcandu's audio adjustments (microphone fix, buffer size) apply to this engine's driver.
    /// `unrecognized` = an engine update changed the driver: the fixes can't be applied, so microphones
    /// may not work there — shown in Diagnostics and in the engine self-test.
    public static func status(driver d: Data) -> DriverStatus {
        let b = [UInt8](d)
        if !offsets(of: halLookup, in: b).isEmpty { return .fixed }
        if !offsets(of: defaultOutputLookup, in: b).isEmpty, immediates(d, value: 100_000).count == 2 { return .needsFix }
        return .unrecognized
    }
    public static func status(host: URL) -> DriverStatus {
        guard let d = try? Data(contentsOf: driver(host)) else { return .missing }
        return status(driver: d)
    }

    /// Does this app's driver still have the microphone bug?
    public static func needsMicrophoneFix(_ host: URL) -> Bool {
        guard let d = try? Data(contentsOf: driver(host)) else { return false }
        return !offsets(of: defaultOutputLookup, in: [UInt8](d)).isEmpty
    }

    /// Writes the adjusted driver for an app (from its saved original), re-signed.
    static func write(ms: Int, host h: URL) throws {
        let fm = FileManager.default
        let drv = driver(h), orig = original(h)
        // Keep the engine's own file once; every change starts from it.
        if !fm.fileExists(atPath: orig.path) {
            let d = try Data(contentsOf: drv)
            guard immediates(d, value: 100_000).count == 2, immediates(d, value: 50_000).count == 2 else {
                throw NokError("This engine's audio driver isn't the version Nokcandu knows how to adjust; nothing was changed.")
            }
            try fm.createDirectory(at: orig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: drv, to: orig)
        }
        let out = try adjusted(try Data(contentsOf: orig), ms: ms)
        let tmp = drv.appendingPathExtension("nokcandu-tmp")
        try? fm.removeItem(at: tmp)
        try out.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        let sign = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", tmp.path], timeout: 60)
        guard sign.ok else { try? fm.removeItem(at: tmp); throw NokError("Couldn't sign the adjusted driver: \(sign.combined.suffix(200))") }
        _ = try fm.replaceItemAt(drv, withItemAt: tmp)
    }

    public static func apply(_ ms: Int, for g: InstalledGame) throws {
        guard choices.contains(ms) else { throw NokError("Unsupported buffer size.") }
        guard let h = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit the game first.") }
        if g.usesSharedSteam || g.isSteamHost, SharedSteam.isRunning { throw NokError("Quit Steam first (Steam page → Quit Steam).") }
        try write(ms: ms, host: h)
    }

    /// Fixes microphone input in every app's engine that still needs it (keeps each app's buffer size).
    /// Replacing the file doesn't disturb a running game — it keeps the copy it loaded until it restarts.
    public static func fixMicrophones(_ games: [InstalledGame]) {
        var hosts = Set<URL>()
        for g in games { if let h = WineTools.hostContents(for: g) { hosts.insert(h) } }
        for h in hosts where needsMicrophoneFix(h) {
            let ms = (try? Data(contentsOf: driver(h))).flatMap { current(driver: $0, original: try? Data(contentsOf: original(h))) } ?? 10
            try? write(ms: ms, host: h)
        }
    }
}
