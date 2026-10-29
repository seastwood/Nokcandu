import Foundation

/// Will this Mac game run on this Mac? Read from the app itself: which processors its program is built for
/// (Mach-O header) and the macOS version it asks for (Info.plist).
public enum MacCompat {
    public enum Verdict: Equatable {
        case native                          // built for Apple silicon
        case rosetta                         // Intel only: runs through Rosetta
        case needsNewerMacOS(String)         // LSMinimumSystemVersion is newer than this Mac
        case unsupported32Bit                // 32-bit only: can't run on any current macOS
        case unknown
    }

    public static func check(_ app: URL, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Verdict {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        if let min = info?["LSMinimumSystemVersion"] as? String, newer(min, than: os) { return .needsNewerMacOS(min) }
        guard let exe = info?["CFBundleExecutable"] as? String,
              let archs = architectures(app.appendingPathComponent("Contents/MacOS/\(exe)")) else { return .unknown }
        if archs.contains("arm64") || archs.contains("arm64e") { return .native }
        if archs.contains("x86_64") { return .rosetta }
        if archs.contains("i386") { return .unsupported32Bit }
        return .unknown
    }

    static func newer(_ v: String, than os: OperatingSystemVersion) -> Bool {
        let p = v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return (p[0], p[1], p[2]) > (os.majorVersion, os.minorVersion, os.patchVersion)
    }

    /// Processor types in a Mach-O program (thin or universal).
    public static func architectures(_ file: URL) -> Set<String>? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), head.count >= 8 else { return nil }
        func u32(_ o: Int, big: Bool) -> UInt32 {
            let v = head.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu { case 0x0100000C: return "arm64"; case 0x01000007: return "x86_64"; case 7: return "i386"; case 12: return "arm"; default: return nil }
        }
        let magic = u32(0, big: true)
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {                       // universal binary
            let n = Int(u32(4, big: true)), stride = magic == 0xCAFEBABF ? 32 : 20
            var out = Set<String>()
            for i in 0..<min(n, 16) where 8 + i * stride + 4 <= head.count { if let a = name(u32(8 + i * stride, big: true)) { out.insert(a) } }
            return out
        }
        let le = u32(0, big: false)
        if le == 0xFEEDFACF || le == 0xFEEDFACE { return name(u32(4, big: false)).map { [$0] } }
        return nil
    }

    /// One plain sentence for the game's page, nil when there's nothing to say.
    public static func note(_ v: Verdict) -> (text: String, warning: Bool)? {
        switch v {
        case .native: return ("Built for Apple silicon — runs natively.", false)
        case .rosetta: return ("Intel-only game: it runs through Rosetta (a little slower). Apple has announced full Rosetta support ends with macOS 28, so this version may stop working then.", true)
        case .needsNewerMacOS(let v): return ("Needs macOS \(v) or newer — this Mac has macOS \(ProcessInfo.processInfo.operatingSystemVersionString). It won't start until macOS is updated.", true)
        case .unsupported32Bit: return ("32-bit game: current macOS can't run it at all. The Windows version (through Wine) may work instead.", true)
        case .unknown: return nil
        }
    }
}
