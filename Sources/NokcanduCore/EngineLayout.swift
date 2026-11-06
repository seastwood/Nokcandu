import Foundation

/// Where a Wine engine keeps its pieces, which depends on the processor it's built for.
///
/// Today's engines are Intel (x86_64) builds that run through Rosetta: unix libraries in lib/wine/x86_64-unix,
/// Windows libraries in x86_64-windows and i386-windows. Native Apple silicon engines (ARM64 Wine, with an
/// x86 emulator such as FEX for Intel Windows programs through ARM64EC/WoW64) keep unix libraries in
/// lib/wine/aarch64-unix and their own Windows libraries in aarch64-windows. Everything in Nokcandu that reaches
/// into an engine asks this type instead of assuming the Intel layout.
public struct EngineLayout: Equatable, Sendable {
    public enum Arch: String, Codable, Sendable {
        case x86_64, arm64
        public var unixFolder: String { self == .arm64 ? "aarch64-unix" : "x86_64-unix" }
        /// The engine's own 64-bit Windows libraries.
        public var windowsFolder: String { self == .arm64 ? "aarch64-windows" : "x86_64-windows" }
        public var title: String { self == .arm64 ? "Apple silicon (ARM)" : "Intel (Rosetta)" }
    }
    public let wine: URL          // …/SharedSupport/wine
    public let arch: Arch

    /// The layout of an app's engine (contents = the app's Contents folder).
    public init(contents: URL) { self.init(wine: contents.appendingPathComponent("SharedSupport/wine")) }
    public init(wine: URL) {
        self.wine = wine
        self.arch = Self.architecture(wine: wine)
    }

    /// ARM when the engine has ARM unix libraries and no Intel ones, or when its loader is an ARM program.
    static func architecture(wine: URL) -> Arch {
        let fm = FileManager.default
        let lib = wine.appendingPathComponent("lib/wine")
        let hasARM = fm.fileExists(atPath: lib.appendingPathComponent("aarch64-unix").path)
        let hasIntel = fm.fileExists(atPath: lib.appendingPathComponent("x86_64-unix").path)
        if hasARM && !hasIntel { return .arm64 }
        if hasIntel { return .x86_64 }
        let archs = MacCompat.architectures(wine.appendingPathComponent("bin/wine")) ?? []
        return archs.contains("arm64") && !archs.contains("x86_64") ? .arm64 : .x86_64
    }

    public var lib: URL { wine.appendingPathComponent("lib/wine") }
    public var unix: URL { lib.appendingPathComponent(arch.unixFolder) }
    /// The real loader Wine 11's ntdll re-executes (lib/wine/<arch>-unix/wine).
    public var loader: URL { unix.appendingPathComponent("wine") }
    public var ntdll: URL { unix.appendingPathComponent("ntdll.so") }
    public func unixLibrary(_ name: String) -> URL { unix.appendingPathComponent(name) }
    /// Path of a file inside lib/wine relative to it, for this engine's processor ("x86_64-unix/winemac.so").
    public func relative(_ intelPath: String) -> String {
        guard arch == .arm64 else { return intelPath }
        return intelPath.replacingOccurrences(of: "x86_64-unix/", with: "aarch64-unix/")
            .replacingOccurrences(of: "x86_64-windows/", with: "aarch64-windows/")
    }

    /// Rosetta is needed for Intel engines only.
    public var needsRosetta: Bool { arch == .x86_64 }

    /// Can this engine run 32-bit Intel Windows programs (most older games)? Intel engines run them through
    /// WoW64 directly; ARM engines need an x86 emulator for 32-bit code (FEX's or Windows' WoW64 module).
    public var runs32BitX86: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lib.appendingPathComponent("i386-windows").path) else { return false }
        guard arch == .arm64 else { return true }
        let emulators = ["libwow64fex.dll", "xtajit.dll", "wow64cpu-fex.dll"]
        return [lib.appendingPathComponent("aarch64-windows"), lib.appendingPathComponent("arm64ec-windows")].contains { dir in
            emulators.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }
    /// Can it run 64-bit Intel Windows programs? ARM engines need an ARM64EC emulator (FEX's).
    public var runs64BitX86: Bool {
        guard arch == .arm64 else { return true }
        let fm = FileManager.default
        return [lib.appendingPathComponent("aarch64-windows"), lib.appendingPathComponent("arm64ec-windows")].contains { dir in
            ["libarm64ecfex.dll", "xtajit64.dll"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    /// Suffix after "SharedSupport/" for any engine's real loader (both layouts), for process ownership checks.
    static let loaderSuffixes = ["wine/lib/wine/x86_64-unix/wine", "wine/lib/wine/aarch64-unix/wine"]
}
