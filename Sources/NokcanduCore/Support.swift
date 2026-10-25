import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Well-known locations. Everything Nokcandu owns lives under Application Support;
/// game apps stay where the user keeps them.
public enum NokPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var gameAppsFolder: URL {
        if let o = ProcessInfo.processInfo.environment["NOKCANDU_GAME_APPS"], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        // Older setups (and Sikarugir users) keep game apps in ~/Applications/Sikarugir; new ones get their own folder.
        let legacy = home.appendingPathComponent("Applications/Sikarugir", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return home.appendingPathComponent("Applications/Nokcandu Games", isDirectory: true)
    }
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Nokcandu", isDirectory: true)
    }
    public static var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    public static var journals: URL { support.appendingPathComponent("Journals", isDirectory: true) }
    public static var diagnostics: URL { support.appendingPathComponent("Diagnostics", isDirectory: true) }
    public static var installs: URL { support.appendingPathComponent("Installs", isDirectory: true) }
    public static var runtimes: URL { support.appendingPathComponent("Runtimes", isDirectory: true) }
    public static var downloads: URL { support.appendingPathComponent("Downloads", isDirectory: true) }

    /// Helper files shipped inside Nokcandu.app/Contents/Resources (python helpers, screen-size tool).
    public static func bundledResource(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            // `swift run` during development: Resources/ next to the package.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(name)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

public struct NokError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Hashing

public enum Hashing {
    public static func sha256(file url: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        let r = try Shell.run("/usr/bin/sha256sum", [url.path])
        return String(r.stdout.prefix(64))
        #endif
    }

    public static func sha256(data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (try? sha256(file: tmp)) ?? ""
        #endif
    }
}

// MARK: - Processes

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
    public var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

public enum Shell {
    /// Runs a tool synchronously with bounded output. Never goes through a shell interpreter,
    /// so paths with spaces and quotes are passed exactly.
    @discardableResult
    public static func run(_ tool: String, _ args: [String], cwd: URL? = nil,
                           env: [String: String]? = nil, timeout: TimeInterval = 120) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { collector.append(out: $0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.append(err: $0.availableData) }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collector.append(out: out.fileHandleForReading.readDataToEndOfFile())
        collector.append(err: err.fileHandleForReading.readDataToEndOfFile())
        return ShellResult(status: p.terminationStatus, stdout: collector.stdout, stderr: collector.stderr)
    }

    /// Async wrapper with cooperative cancellation (terminates the child on cancel).
    public static func runAsync(_ tool: String, _ args: [String], cwd: URL? = nil,
                                env: [String: String]? = nil, timeout: TimeInterval = 3600,
                                onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collector.append(out: d)
            if let onOutput, let s = String(data: d, encoding: .utf8), !s.isEmpty { onOutput(s) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collector.append(err: d)
            if let onOutput, let s = String(data: d, encoding: .utf8), !s.isEmpty { onOutput(s) }
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        try await withTaskCancellationHandler {
            while p.isRunning {
                if Date() > deadline { p.terminate(); throw NokError("Timed out: \(URL(fileURLWithPath: tool).lastPathComponent)") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } onCancel: {
            p.terminate()
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        return ShellResult(status: p.terminationStatus, stdout: collector.stdout, stderr: collector.stderr)
    }

    public static func which(_ name: String, extra: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]) -> String? {
        for dir in extra {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// Thread-safe, size-bounded output buffer (keeps the most recent ~256 KB per stream).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private let limit = 256 * 1024
    func append(out d: Data) { lock.lock(); out.append(d); if out.count > limit { out = out.suffix(limit) }; lock.unlock() }
    func append(err d: Data) { lock.lock(); err.append(d); if err.count > limit { err = err.suffix(limit) }; lock.unlock() }
    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

// MARK: - Display

public struct DesktopSize: Codable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var description: String { "\(width) × \(height)" }

    /// Current scaled (logical) desktop of the main display — never the physical Retina pixels.
    public static func current() -> DesktopSize {
        #if canImport(CoreGraphics)
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0, mode.height > 0 {
            return DesktopSize(width: mode.width, height: mode.height)
        }
        #endif
        return DesktopSize(width: 1280, height: 800)
    }
}

// MARK: - Small file helpers

public extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    func availableCapacity(at url: URL) -> Int64? {
        var probe = url
        while !fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// APFS clone when possible (instant, no extra space until modified); falls back to a normal copy.
    func cloneItem(at src: URL, to dst: URL) throws {
        try createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try Shell.run("/bin/cp", ["-cR", src.path, dst.path], timeout: 1800)
        if !r.ok {
            let r2 = try Shell.run("/bin/cp", ["-R", src.path, dst.path], timeout: 3600)
            if !r2.ok { throw NokError("Copy failed: \(r2.combined)") }
        }
    }
}

/// Last `maxLines` lines of a text file, read from the end so huge logs stay cheap.
public func tailOfFile(_ url: URL, maxLines: Int = 40, maxBytes: Int = 64 * 1024) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? h.seek(toOffset: start)
    let data = (try? h.readToEnd()) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    return text.components(separatedBy: .newlines).suffix(maxLines).joined(separator: "\n")
}

// MARK: - iCloud-safe reads

/// Reads a small text file that may live in an iCloud-synced folder (e.g. ~/Documents with
/// "Optimize Mac Storage"). Evicted files are asked to download first, and the read gives up after
/// `timeout` instead of blocking forever. Returns nil if the file is missing or not available in time.
public func readTextAllowingCloud(_ url: URL, timeout: TimeInterval = 4) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return nil }
    if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
       let status = v.ubiquitousItemDownloadingStatus, status != .current {
        try? fm.startDownloadingUbiquitousItem(at: url)
    }
    let box = Locked<String?>(nil)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = try? String(contentsOf: url, encoding: .utf8)
        done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success ? box.value : nil
}

/// True when a file in an iCloud-synced folder is currently not downloaded to this Mac.
public func isCloudOnly(_ url: URL) -> Bool {
    guard let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
          let s = v.ubiquitousItemDownloadingStatus else { return false }
    return s == .notDownloaded
}
