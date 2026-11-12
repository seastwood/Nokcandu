import Foundation
import Darwin

/// Verified USB controller compatibility: Pro descriptor and original wired Steam HID.
/// Only a fingerprinted Wine module can be updated, with idle checks and original recovery.
public enum ControllerHIDFix {
    public enum State: String, Sendable { case unavailable, pending, installed, modified, disabled }
    struct Manifest: Codable {
        var version: String
        var sourceSHA256: String
        var stockSHA256: [String]
    }
    struct Stamp: Codable {
        var original: String
        var source: String
        var installed: String
    }
    private static let lock = NSRecursiveLock()
    static var bundle: URL? { NokPaths.bundledResource("controller-hid/11.0") }
    static func target(_ c: URL) -> URL { c.resolvingSymlinksInPath().appendingPathComponent("SharedSupport/wine/lib/wine/x86_64-unix/winebus.so") }
    static func folder(_ c: URL) -> URL { c.resolvingSymlinksInPath().appendingPathComponent("SharedSupport/nokcandu/controller-hid-original") }
    static func disabled(_ c: URL) -> URL { folder(c).appendingPathComponent("disabled") }
    static func stampURL(_ c: URL) -> URL { folder(c).appendingPathComponent("installed.json") }
    static func backup(_ c: URL, _ hash: String) -> URL { folder(c).appendingPathComponent(hash).appendingPathComponent("winebus.so") }
    static func safe(_ u: URL) -> Bool { u.standardizedFileURL == u.resolvingSymlinksInPath().standardizedFileURL }
    static func hash(_ u: URL) -> String? { try? Hashing.sha256(file: u) }
    static func metadata(_ b: URL) throws -> Manifest {
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: b.appendingPathComponent("manifest.json")))
        func valid(_ h: String) -> Bool { h.count == 64 && h.allSatisfy { "0123456789abcdef".contains($0) } }
        guard m.version == "11.0", valid(m.sourceSHA256), !m.stockSHA256.isEmpty,
              m.stockSHA256.allSatisfy(valid), hash(b.appendingPathComponent("winebus.so")) == m.sourceSHA256 else {
            throw NokError("The controller input correction did not pass verification.")
        }
        return m
    }
    static func stamp(_ c: URL) -> Stamp? { (try? Data(contentsOf: stampURL(c))).flatMap { try? JSONDecoder().decode(Stamp.self, from: $0) } }
    public static func state(contents: URL) -> State { state(contents: contents, bundle: bundle) }
    static func state(contents c: URL, bundle b: URL?) -> State {
        guard let b, let m = try? metadata(b), WindowedPresentation.engineVersion(host: c).map({ $0.major == 11 && $0.minor == 0 }) == true,
              EngineLayout(contents: c).arch == .x86_64 else { return .unavailable }
        guard safe(target(c)), safe(folder(c)), safe(stampURL(c)), safe(disabled(c)) else { return .modified }
        if FileManager.default.fileExists(atPath: disabled(c).path) { return .disabled }
        let current = hash(target(c))
        if let s = stamp(c), current == s.installed, m.stockSHA256.contains(s.original), hash(backup(c,s.original)) == s.original {
            return s.source == m.sourceSHA256 ? .installed : .pending
        }
        return current.map { m.stockSHA256.contains($0) } == true ? .pending : .modified
    }
    public static func refresh(contents: URL) {
        guard let b = bundle else { return }
        _ = try? install(contents: contents, bundle: b, snapshot: GameLauncher.freshProcessStatus())
    }
    @discardableResult
    static func install(contents c: URL, bundle b: URL, snapshot: ProcessSnapshot,
                        sign: (URL) throws -> Void = signLibrary) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Controllers.environmentClosed(contents: c, snapshot: snapshot) else { return false }
        let m = try metadata(b), fm = FileManager.default
        let state = state(contents: c, bundle: b)
        if state == .installed || state == .disabled || state == .unavailable { return false }
        guard state == .pending, let current = hash(target(c)) else { throw NokError("The controller driver was edited or is not a recognized build. It was preserved.") }
        let original: String
        if m.stockSHA256.contains(current) { original = current }
        else if let s = stamp(c), s.installed == current, m.stockSHA256.contains(s.original) { original = s.original }
        else { throw NokError("The original controller driver cannot be verified.") }
        let saved = backup(c,original)
        guard safe(saved) else { throw NokError("The controller driver recovery path is linked. It was preserved.") }
        if !fm.fileExists(atPath: saved.path) {
            guard current == original else { throw NokError("The original controller driver recovery copy is missing.") }
            try NokPaths.ensure(saved.deletingLastPathComponent())
            try Data(contentsOf: target(c)).write(to: saved, options: .withoutOverwriting)
        }
        guard hash(saved) == original else { throw NokError("The original controller driver recovery copy was changed. It was preserved.") }
        let staged = target(c).deletingLastPathComponent().appendingPathComponent(".nok-controller-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: b.appendingPathComponent("winebus.so"), to: staged)
        try sign(staged)
        guard let installed = hash(staged), hash(target(c)) == current else { throw NokError("The controller driver changed during preparation; update cancelled.") }
        try NokPaths.ensure(folder(c))
        try JSONEncoder().encode(Stamp(original: original, source: m.sourceSHA256, installed: installed)).write(to: stampURL(c), options: .atomic)
        guard rename(staged.path,target(c).path) == 0 else { throw NokError("The controller driver update could not be installed. Its original recovery copy was retained.") }
        return true
    }
    private static func signLibrary(_ u: URL) throws {
        let r = try Shell.run("/usr/bin/codesign", ["--force","--sign","-",u.path])
        guard r.ok else { throw NokError("The controller driver could not be signed. The installed copy was preserved.") }
    }
    public static func setEnabled(_ on: Bool, contents c: URL) throws {
        guard let b = bundle else { throw NokError("This app has no controller input correction.") }
        try setEnabled(on, contents: c, bundle: b, snapshot: GameLauncher.freshProcessStatus())
    }
    static func setEnabled(_ on: Bool, contents c: URL, bundle b: URL, snapshot: ProcessSnapshot,
                           sign: (URL) throws -> Void = signLibrary) throws {
        lock.lock(); defer { lock.unlock() }
        guard Controllers.environmentClosed(contents: c, snapshot: snapshot) else { throw NokError("Quit this environment's games and launcher normally before changing the controller driver.") }
        let m = try metadata(b), fm = FileManager.default
        guard safe(target(c)), safe(folder(c)), safe(disabled(c)), safe(stampURL(c)) else { throw NokError("The controller driver or recovery path is linked. It was preserved.") }
        if on {
            if fm.fileExists(atPath: disabled(c).path) { try fm.removeItem(at: disabled(c)) }
            _ = try install(contents: c, bundle: b, snapshot: snapshot, sign: sign)
        } else {
            guard let s = stamp(c), m.stockSHA256.contains(s.original), hash(target(c)) == s.installed,
                  safe(backup(c,s.original)), hash(backup(c,s.original)) == s.original else {
                throw NokError("The original controller driver or installed correction changed. Nothing was restored.")
            }
            let staged = target(c).deletingLastPathComponent().appendingPathComponent(".nok-controller-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: backup(c,s.original), to: staged)
            // Write the opt-out first so an interrupted restore is never automatically reinstalled.
            try Data("1\n".utf8).write(to: disabled(c), options: .atomic)
            guard hash(target(c)) == s.installed, rename(staged.path,target(c).path) == 0 else {
                try? fm.removeItem(at: disabled(c))
                throw NokError("The controller driver changed during restoration. Its recovery copy was preserved.")
            }
        }
    }
}
