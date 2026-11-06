import Foundation

/// Setups Nokcandu knows for particular games (beyond what its files suggest): shown as one card at the top of
/// the game's page until applied or dismissed. Each applies through the usual undoable settings and fixes.
public enum GameSetups {
    public enum Kind: String, Sendable { case overwatch, bf1942 }
    public struct Setup: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        public var detail: String
        public var button: String
    }

    public static func overwatchComplete(_ g: InstalledGame) -> Bool {
        BattleNetGraphics.choice(g) == .dxmt && CompatibilityFixes.isInstalled(.dxmtLowMemory, for: g)
    }

    /// The setup this game still needs, if Nokcandu knows one and it wasn't dismissed. Call off the main thread.
    public static func pending(_ g: InstalledGame) -> Setup? {
        guard g.native == nil, !dismissed(g) else { return nil }
        if g.battleNet?.isOverwatch == true, !overwatchComplete(g) {
            return Setup(kind: .overwatch, title: "Recommended for Overwatch 2",
                         detail: "Metal for DirectX 10–11 (DXMT) with the low-memory DXMT build: the game stays around 4 GB of memory instead of growing past 13 GB, without killcam and respawn stutter. Undo is in Fixes.",
                         button: "Use Recommended Setup")
        }
        if BF1942DisplayFix.supports(g), !BF1942DisplayFix.hasChanges(for: g) {
            return Setup(kind: .bf1942, title: "Recommended for Battlefield 1942",
                         detail: "A corrected menu at your screen's size, 1280 × 800 windowed gameplay and the working Internet server list. The original program is kept; Undo is in Display.",
                         button: "Use Recommended Setup")
        }
        return nil
    }

    public static func apply(_ kind: Kind, to g: InstalledGame, games: [InstalledGame], log: @escaping @Sendable (String) -> Void) async throws {
        switch kind {
        case .overwatch:
            if BattleNetGraphics.choice(g) != .dxmt { try BattleNetGraphics.set(.dxmt, for: g, games: games) }
            let fresh = GameLibrary.inspect(g.appURL) ?? g
            if !CompatibilityFixes.isInstalled(.dxmtLowMemory, for: fresh) {
                try await CompatibilityFixes.install(.dxmtLowMemory, for: fresh, log: log)
            }
        case .bf1942:
            try await BF1942DisplayFix.applyRecommendedSetup(to: g, log: log)
        }
    }

    static func dismissedFile(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("setup-dismissed") }
    static func dismissed(_ g: InstalledGame) -> Bool { FileManager.default.fileExists(atPath: dismissedFile(g).path) }
    public static func dismiss(_ g: InstalledGame) {
        try? NokPaths.ensure(g.nokcanduState)
        FileManager.default.createFile(atPath: dismissedFile(g).path, contents: Data())
    }
    static func undismiss(_ g: InstalledGame) { try? FileManager.default.removeItem(at: dismissedFile(g)) }

    /// "Reset to Recommended": a restore point first, then every fix Nokcandu installed is undone, earlier "Not Now"
    /// choices are forgotten and the recommended setup is applied again. Game files, saves and options aren't touched.
    /// Returns what couldn't be applied.
    public static func resetToRecommended(_ g: InstalledGame, games: [InstalledGame], log: @escaping @Sendable (String) -> Void) async throws -> [String] {
        RestorePoints.before(g, "Before Reset to Recommended", log: log)
        for fix in CompatibilityFix.allCases where CompatibilityFixes.isInstalled(fix, for: g) {
            log("Undoing \(fix.title)…")
            try CompatibilityFixes.undo(fix, for: GameLibrary.inspect(g.appURL) ?? g, log: log)
        }
        try? FileManager.default.removeItem(at: Recommendations.dismissedFile(g))
        undismiss(g)
        var fresh = GameLibrary.inspect(g.appURL) ?? g
        if let setup = pending(fresh) {
            try await apply(setup.kind, to: fresh, games: games, log: log)
            fresh = GameLibrary.inspect(g.appURL) ?? fresh
        }
        let recs = Recommendations.forGame(fresh)
        return recs.isEmpty ? [] : try await Recommendations.apply(recs, to: fresh, log: log)
    }
}
