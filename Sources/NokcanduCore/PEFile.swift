import Foundation

/// What Nokcandu reads from a Windows .exe: bitness, imported DLLs (to suggest a graphics mode),
/// and the original icon. Read-only; the file is never modified.
public struct PEInfo: Equatable {
    public var is64Bit: Bool
    public var imports: [String]
}

public enum PEFile {
    struct Section { var va: UInt32; var vsize: UInt32; var raw: UInt32; var rawSize: UInt32 }

    struct Parsed {
        var data: Data
        var is64: Bool
        var sections: [Section]
        var dirs: [(rva: UInt32, size: UInt32)]

        func u16(_ o: Int) -> UInt16? { o >= 0 && o + 2 <= data.count ? data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian : nil }
        func u32(_ o: Int) -> UInt32? { o >= 0 && o + 4 <= data.count ? data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian : nil }
        func offset(rva: UInt32) -> Int? {
            for s in sections where rva >= s.va && rva < s.va &+ max(s.vsize, s.rawSize) {
                let o = Int(rva - s.va) + Int(s.raw)
                return o < data.count ? o : nil
            }
            return nil
        }
        func cString(at o: Int, max: Int = 256) -> String? {
            guard o >= 0, o < data.count else { return nil }
            let end = data[o..<min(data.count, o + max)].firstIndex(of: 0) ?? min(data.count, o + max)
            return String(data: data[o..<end], encoding: .ascii)
        }
    }

    static func parse(_ data: Data) -> Parsed? {
        var p = Parsed(data: data, is64: false, sections: [], dirs: [])
        guard data.count > 0x40, p.u16(0) == 0x5A4D, let lfanew = p.u32(0x3C).map(Int.init),
              p.u32(lfanew) == 0x0000_4550,
              let nsec = p.u16(lfanew + 6), let optSize = p.u16(lfanew + 20) else { return nil }
        let opt = lfanew + 24
        guard let magic = p.u16(opt) else { return nil }
        p.is64 = magic == 0x20B
        let ddOff = opt + (p.is64 ? 112 : 96)
        let nDirs = Int(p.u32(ddOff - 4) ?? 0)
        for i in 0..<min(nDirs, 16) {
            p.dirs.append((p.u32(ddOff + i * 8) ?? 0, p.u32(ddOff + i * 8 + 4) ?? 0))
        }
        let secOff = opt + Int(optSize)
        for i in 0..<Int(nsec) {
            let o = secOff + i * 40
            guard let vs = p.u32(o + 8), let va = p.u32(o + 12), let rs = p.u32(o + 16), let rp = p.u32(o + 20) else { break }
            p.sections.append(Section(va: va, vsize: vs, raw: rp, rawSize: rs))
        }
        return p
    }

    public static func inspect(_ url: URL) -> PEInfo? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let p = parse(data) else { return nil }
        var imports: [String] = []
        if p.dirs.count > 1, p.dirs[1].rva != 0, var o = p.offset(rva: p.dirs[1].rva) {
            for _ in 0..<512 {
                guard let nameRVA = p.u32(o + 12), nameRVA != 0 else { break }
                if let no = p.offset(rva: nameRVA), let n = p.cString(at: no) { imports.append(n) }
                o += 20
            }
        }
        return PEInfo(is64Bit: p.is64, imports: imports)
    }

    private static let graphicsDLLs: Set<String> = ["d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "ddraw.dll", "opengl32.dll"]

    /// Include runtime graphics names and imported engine DLLs beside the executable.
    /// Many games put OpenGL/DirectX imports in their engine rather than their main program.
    /// Direct evidence in the executable retains precedence. Never search Windows/PATH or
    /// unrelated DLLs; cap the dependency walk and keep it inside the game's real directory.
    public static func inspectWithLoadedDLLs(_ url: URL) -> PEInfo? {
        guard var info = inspect(url) else { return nil }
        func graphics(_ names: [String]) -> [String] {
            names.filter { graphicsDLLs.contains($0.lowercased()) }
        }
        if !graphics(info.imports).isEmpty { return info }
        let loaded = loadedGraphicsDLLs(url)
        if !loaded.isEmpty { info.imports += loaded; return info }

        let root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        var local: [String:URL] = [:], ambiguous = Set<String>()
        for file in files where file.pathExtension.lowercased() == "dll" {
            let key = file.lastPathComponent.lowercased()
            // A case-sensitive directory can contain ambiguous Windows names. Do not guess.
            if local[key] != nil { ambiguous.insert(key); continue }
            local[key] = file
        }
        var pending = info.imports.filter { local[$0.lowercased()] != nil }, visited = Set<String>(), found = Set<String>()
        var index = 0, bytesRemaining = 256 * 1024 * 1024
        while index < pending.count && visited.count < 64 {
            let name = pending[index].lowercased(); index += 1
            guard visited.insert(name).inserted, !ambiguous.contains(name), let file = local[name] else { continue }
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent() == root,
                  let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= min(64 * 1024 * 1024, bytesRemaining),
                  let dependency = inspect(resolved), dependency.is64Bit == info.is64Bit else { continue }
            bytesRemaining -= size
            let direct = graphics(dependency.imports)
            found.formUnion((direct.isEmpty ? loadedGraphicsDLLs(resolved) : direct).map { $0.lowercased() })
            pending += dependency.imports.filter { local[$0.lowercased()] != nil }
        }
        info.imports += found.sorted()
        return info
    }

    static func loadedGraphicsDLLs(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let names = ["d3d12.dll", "d3d11.dll", "dxgi.dll", "d3d10.dll", "d3d9.dll", "d3d8.dll", "ddraw.dll", "opengl32.dll"]
        var found: [String] = []
        for n in names {
            // ASCII and UTF-16LE spellings, any case.
            let lower = Data(n.utf8), upper = Data(n.uppercased().utf8)
            let wide = Data(n.utf8.flatMap { [$0, 0] }), wideUp = Data(n.uppercased().utf8.flatMap { [$0, 0] })
            if [lower, upper, wide, wideUp].contains(where: { data.range(of: $0) != nil }) { found.append(n) }
        }
        return found
    }

    /// Builds a single-image .ico from the exe's largest group icon. Returns nil when there is none.
    public static func largestIcon(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let p = parse(data),
              p.dirs.count > 2, p.dirs[2].rva != 0, let root = p.offset(rva: p.dirs[2].rva) else { return nil }

        // Resource tree: type → name/id → language → data entry.
        func entries(_ dirOff: Int) -> [(id: UInt32, isDir: Bool, off: Int)] {
            guard let named = p.u16(dirOff + 12), let ids = p.u16(dirOff + 14) else { return [] }
            var out: [(UInt32, Bool, Int)] = []
            for i in 0..<min(Int(named) + Int(ids), 4096) {
                let e = dirOff + 16 + i * 8
                guard let name = p.u32(e), let target = p.u32(e + 4) else { break }
                out.append((name, target & 0x8000_0000 != 0, root + Int(target & 0x7FFF_FFFF)))
            }
            return out
        }
        func firstLeaf(_ off: Int, isDir: Bool, depth: Int = 0) -> Data? {
            if !isDir {
                guard let rva = p.u32(off), let size = p.u32(off + 4), let o = p.offset(rva: rva), o + Int(size) <= p.data.count else { return nil }
                return p.data.subdata(in: o..<(o + Int(size)))
            }
            guard depth < 4 else { return nil }
            for e in entries(off) { if let d = firstLeaf(e.off, isDir: e.isDir, depth: depth + 1) { return d } }
            return nil
        }
        let types = entries(root)
        guard let groupType = types.first(where: { $0.id == 14 }), let iconType = types.first(where: { $0.id == 3 }) else { return nil }
        var icons: [UInt32: Data] = [:]
        for e in entries(iconType.off) where e.id & 0x8000_0000 == 0 {
            if let d = firstLeaf(e.off, isDir: e.isDir) { icons[e.id] = d }
        }
        guard let groupEntry = entries(groupType.off).first, let group = firstLeaf(groupEntry.off, isDir: groupEntry.isDir),
              group.count >= 6 else { return nil }
        let g = Parsed(data: group, is64: false, sections: [], dirs: [])
        let count = Int(g.u16(4) ?? 0)
        var best: (w: Int, bpp: Int, entry: Data, image: Data)?
        for i in 0..<count {
            let o = 6 + i * 14
            guard o + 14 <= group.count, let bpp = g.u16(o + 6), let id = g.u16(o + 12), let img = icons[UInt32(id)] else { continue }
            let w = Int(group[o]) == 0 ? 256 : Int(group[o])
            if best == nil || w > best!.w || (w == best!.w && Int(bpp) > best!.bpp) {
                best = (w, Int(bpp), group.subdata(in: o..<(o + 12)), img)
            }
        }
        guard let b = best else { return nil }
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(b.entry)                                     // width..bytesInRes (12 bytes)
        var offset = UInt32(6 + 16).littleEndian
        ico.append(Data(bytes: &offset, count: 4))
        ico.append(b.image)
        return ico
    }

    /// Extracts the exe's icon and converts it to .icns with macOS's own `sips`. Returns true on success.
    @discardableResult
    public static func writeIcns(from exe: URL, to icns: URL, workDir: URL) -> Bool {
        guard let ico = largestIcon(exe) else { return false }
        try? NokPaths.ensure(workDir)
        let icoURL = workDir.appendingPathComponent("icon.ico"), png = workDir.appendingPathComponent("icon.png")
        guard (try? ico.write(to: icoURL)) != nil else { return false }
        _ = try? Shell.run("/usr/bin/sips", ["-s", "format", "png", icoURL.path, "--out", png.path])
        guard FileManager.default.fileExists(atPath: png.path) else { return false }
        // Upscale small originals so Finder doesn't show a postage stamp; keeps the original artwork.
        _ = try? Shell.run("/usr/bin/sips", ["-Z", "512", png.path])
        let r = try? Shell.run("/usr/bin/sips", ["-s", "format", "icns", png.path, "--out", icns.path])
        return r?.ok == true && FileManager.default.fileExists(atPath: icns.path)
    }
}
