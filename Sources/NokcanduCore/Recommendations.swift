import Foundation

/// "Recommended setup" for a Windows game: what to change, and the evidence for each change, read from
/// the game's own files (which DirectX libraries its program and DLLs use), its last launch log and
/// community fixes. Nothing here changes the game; applying goes through the usual undoable fixes.
public struct Recommendation: Hashable, Sendable, Identifiable {
    public enum Action: Hashable, Sendable {
        case graphics(GraphicsPreset)
        case fix(CompatibilityFix)
        case cinematic
        case arguments(String)
        case knownFix(KnownFix)
    }
    public var action: Action
    public var title: String
    /// Why: the evidence, in words ("Bf1942.exe uses DirectX 8 (d3d8.dll)").
    public var reason: String
    public var id: String {
        switch action {
        case .graphics(let p): "graphics-\(p.rawValue)"
        case .fix(let f): "fix-\(f.rawValue)"
        case .cinematic: "cinematic"
        case .arguments(let a): "args-\(a)"
        case .knownFix(let k): "known-\(k.fingerprint.prefix(12))"
        }
    }
    /// Order they're applied in: graphics first (some fixes need a particular mode).
    var order: Int {
        switch action { case .graphics: 0; case .arguments: 1; case .fix: 2; case .cinematic: 3; case .knownFix: 4 }
    }
}

public enum Recommendations {
    /// What a game's files use, found by reading the import tables of its program and the DLLs beside it.
    public struct Evidence: Equatable, Sendable {
        public var program: String
        public var is64Bit: Bool
        /// Lower-cased DLL name → the first file (program or DLL) that imports it.
        public var importedBy: [String: String]
        /// Lower-cased DLLs the game ships in its own folder.
        public var shipped: Set<String>
        public var programImports: Set<String>
        /// Graphics evidence reached through the program and its imported local engine DLLs.
        public var graphicsImports: Set<String>
        public init(program: String, is64Bit: Bool, importedBy: [String: String], shipped: Set<String>, programImports: Set<String>, graphicsImports: Set<String>? = nil) {
            self.program = program; self.is64Bit = is64Bit; self.importedBy = importedBy; self.shipped = shipped; self.programImports = programImports
            self.graphicsImports = graphicsImports ?? programImports
        }
    }

    public static func evidence(program exe: URL) -> Evidence? {
        guard let pe = PEFile.inspect(exe) else { return nil }
        let name = exe.lastPathComponent
        var by: [String: String] = [:]
        for i in pe.imports { by[i.lowercased()] = by[i.lowercased()] ?? name }
        let dir = exe.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let dlls = files.filter { $0.pathExtension.lowercased() == "dll" }
        // The game's own DLLs often hold the renderer (e.g. an engine's d3d9 module).
        for d in dlls.prefix(60) {
            guard ((try? d.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 80 << 20, let info = PEFile.inspect(d) else { continue }
            for i in info.imports { by[i.lowercased()] = by[i.lowercased()] ?? d.lastPathComponent }
        }
        return Evidence(program: name, is64Bit: pe.is64Bit, importedBy: by,
                        shipped: Set(dlls.map { $0.lastPathComponent.lowercased() }),
                        programImports: Set(pe.imports.map { $0.lowercased() }),
                        graphicsImports: Set((PEFile.inspectWithLoadedDLLs(exe) ?? pe).imports.map { $0.lowercased() }))
    }

    /// The rules, kept free of file access so they can be tested.
    public static func recommend(_ e: Evidence, graphics: GraphicsPreset, confirmedGraphics: GraphicsPreset?,
                                 installed: Set<CompatibilityFix>, usesDirectShow: Bool = false, cinematicPresent: Bool = false) -> [Recommendation] {
        var out: [Recommendation] = []
        func uses(_ dll: String) -> String? { e.importedBy[dll] }
        let p = e.graphicsImports
        let modernAPI = ["d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"].contains { p.contains($0) }
        let dx9 = p.contains("d3d9.dll"), dx8 = p.contains("d3d8.dll"), ddraw = p.contains("ddraw.dll")

        // Graphics mode — only when the current one can't suit what the program uses, and the
        // player hasn't marked the current one as playing well.
        var mode: GraphicsPreset?
        var why = ""
        if p.contains("d3d12.dll"), let f = uses("d3d12.dll"), e.is64Bit, graphics != .appleMetal {
            mode = .appleMetal; why = "\(f) uses DirectX 12 (d3d12.dll), which only Apple Metal runs."
        } else if dx8, !modernAPI, !e.is64Bit, graphics != .classic3D {
            mode = .classic3D; why = "\(e.program) uses DirectX 8 (d3d8.dll)."
        } else if dx9, !modernAPI, [.modern3D, .appleMetal, .dxmt].contains(graphics) {
            mode = .classic3D; why = "\(e.program) uses DirectX 9 (d3d9.dll); \(graphics.title) is for DirectX 10 and newer."
        } else if ddraw, !dx8, !dx9, !modernAPI, [.modern3D, .appleMetal, .dxmt].contains(graphics) {
            mode = .classic2D; why = "\(e.program) draws with DirectDraw (ddraw.dll), from the late-'90s."
        } else if p.contains("d3d11.dll") || p.contains("dxgi.dll"), !dx9, [.classic3D, .classic2D].contains(graphics) {
            mode = .modern3D; why = "\(e.program) uses DirectX 11 (d3d11.dll); \(graphics.title) is for DirectX 9 and older."
        } else if p.contains("opengl32.dll"),
                  !p.contains(where: { $0.hasPrefix("d3d") || $0 == "dxgi.dll" || $0 == "ddraw.dll" }),
                  graphics != .compatible {
            mode = .compatible
            why = "\(uses("opengl32.dll") ?? e.program) uses OpenGL (opengl32.dll). Compatibility keeps Wine's own graphics path, including video presentation."
        }
        if let m = mode, confirmedGraphics != graphics {
            out.append(Recommendation(action: .graphics(m), title: "Graphics: \(m.title)", reason: why))
        }
        let finalMode = (confirmedGraphics != graphics ? mode : nil) ?? graphics

        if dx8, !e.is64Bit, finalMode == .classic3D, !installed.contains(.d3d8to9) {
            out.append(Recommendation(action: .fix(.d3d8to9), title: CompatibilityFix.d3d8to9.title,
                                      reason: "\(e.program) uses DirectX 8 (d3d8.dll); running it through DirectX 9 avoids Wine's DirectX 8 glitches."))
        }
        if !installed.contains(.directx9Extras),
           let hit = e.importedBy.keys.sorted().first(where: { $0.hasPrefix("d3dx9_") || $0 == "d3dcompiler_43.dll" }),
           !e.shipped.contains(hit) {
            out.append(Recommendation(action: .fix(.directx9Extras), title: CompatibilityFix.directx9Extras.title,
                                      reason: "\(e.importedBy[hit]!) needs Microsoft's \(hit), which Wine only imitates."))
        }
        if !installed.contains(.shaderCompiler47), let f = uses("d3dcompiler_47.dll"), !e.shipped.contains("d3dcompiler_47.dll") {
            out.append(Recommendation(action: .fix(.shaderCompiler47), title: CompatibilityFix.shaderCompiler47.title,
                                      reason: "\(f) compiles shaders with d3dcompiler_47.dll and the game doesn't include it."))
        }
        if usesDirectShow, !cinematicPresent {
            out.append(Recommendation(action: .cinematic, title: "Cinematic fix (video playback)",
                                      reason: "\(e.program) plays videos through DirectShow, which Wine lacks the decoders for."))
        }
        return out
    }

    /// Everything known for this game right now (file reads; call off the main thread). Community fixes
    /// are added by `withKnownFix`.
    public static func forGame(_ g: InstalledGame) -> [Recommendation] {
        guard let c = g.custom, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil, g.native == nil,
              let exe = CompatibilityFixes.managedProgram(g), let e = evidence(program: exe) else { return [] }
        let installed = Set(CompatibilityFix.allCases.filter { CompatibilityFixes.isInstalled($0, for: g) })
        var out = recommend(e, graphics: c.graphics, confirmedGraphics: c.confirmedGraphics, installed: installed,
                            usesDirectShow: CinematicFix.likelyUsesDirectShow(g), cinematicPresent: CinematicFix.isPresent(for: g))
        // Problems seen in the last launch outrank guesses from the files.
        if let h = CrashHints.diagnose(g) {
            if let m = h.suggested.first {
                out.removeAll { if case .graphics = $0.action { return true }; return false }
                out.insert(Recommendation(action: .graphics(m), title: "Graphics: \(m.title)", reason: "\(h.title) — last launch: \(h.evidence)"), at: 0)
            }
            if let a = h.addArguments {
                out.append(Recommendation(action: .arguments(a), title: "Launch options: \(a)", reason: "\(h.title) — last launch: \(h.evidence)"))
            }
        }
        // Fixes this game can't take (e.g. 64-bit) are left out.
        out.removeAll {
            guard case .fix(let f) = $0.action, let why = CompatibilityFixes.unavailable(f, for: g) else { return false }
            return !(f == .d3d8to9 && why.contains("Older 3D"))
        }
        return out.filter { !dismissed(g).contains($0.id) }
    }

    public static func withKnownFix(_ list: [Recommendation], _ fix: KnownFix?, for g: InstalledGame) -> [Recommendation] {
        guard let fix, !fix.isEmpty, KnownFixes.handled(g) != fix.fingerprint else { return list }
        let r = Recommendation(action: .knownFix(fix), title: "Proton community fixes",
                               reason: fix.summary.isEmpty ? "Fixes Linux players use for this game (umu-protonfixes)." : fix.summary)
        return dismissed(g).contains(r.id) ? list : list + [r]
    }

    // MARK: Not Now

    static func dismissedFile(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("recommendations-dismissed.txt") }
    static func dismissed(_ g: InstalledGame) -> Set<String> {
        Set(((try? String(contentsOf: dismissedFile(g), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    }
    public static func dismiss(_ ids: [String], for g: InstalledGame) {
        try? NokPaths.ensure(g.nokcanduState)
        try? dismissed(g).union(ids).sorted().joined(separator: "\n").write(to: dismissedFile(g), atomically: true, encoding: .utf8)
    }

    // MARK: Applying

    /// Applies the chosen recommendations in a safe order. Each one is its own undoable change (graphics
    /// in Settings, fixes in Fixes). Returns what couldn't be applied, in words.
    @discardableResult
    public static func apply(_ chosen: [Recommendation], to game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws -> [String] {
        if case .launcherRunning = GameLauncher.runState(of: game) { throw NokError("Quit \(game.name) first.") }
        RestorePoints.before(game, "Before recommended setup", log: log)
        var skipped: [String] = []
        for r in chosen.sorted(by: { $0.order < $1.order }) {
            let g = GameLibrary.inspect(game.appURL) ?? game
            log(r.title + "…")
            switch r.action {
            case .graphics(let p):
                guard var c = g.custom else { continue }
                if c.legacyD3D9 == true && p != .classic3D { skipped.append("\(r.title): undo DirectX 8 compatibility in Fixes first."); continue }
                c.graphics = p
                try CustomGames.save(c, to: g)
            case .arguments(let a):
                guard var c = g.custom else { continue }
                if !c.arguments.contains(a) { c.arguments = (c.arguments + " " + a).trimmingCharacters(in: .whitespaces) }
                try CustomGames.save(c, to: g)
            case .fix(let f):
                if let why = CompatibilityFixes.unavailable(f, for: g) { skipped.append("\(r.title): \(why)"); continue }
                if CompatibilityFixes.isInstalled(f, for: g) { continue }
                try await CompatibilityFixes.install(f, for: g, log: log)
            case .cinematic:
                if !CinematicFix.isPresent(for: g) { try await CinematicFix.install(for: g, log: log) }
            case .knownFix(let k):
                try await KnownFixes.apply(k, to: g, log: log)
            }
        }
        return skipped
    }
}
