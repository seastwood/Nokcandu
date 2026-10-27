import Foundation

/// A second entry point to the same borderless component shown in Fixes, with one installation record.
public enum GameWindowStyle {
    public static func apply(borderless: Bool, to game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        let g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        if borderless {
            if CompatibilityFixes.isInstalled(.borderless, for: g) {
                guard var c = g.custom else { throw NokError("This game has no managed settings.") }
                c.borderless = true; try CustomGames.save(c, to: g)
            } else { try await CompatibilityFixes.installReserved(.borderless, for: g, log: log) }
        } else if CompatibilityFixes.isInstalled(.borderless, for: g) {
            try CompatibilityFixes.undoReserved(.borderless, for: g, log: log)
        } else if var c = g.custom, c.borderless == true {
            c.borderless = nil; try CustomGames.save(c, to: g)
        }
    }
}
