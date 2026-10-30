import Foundation

/// Settings ▸ Window style.
public enum GameWindowStyle: String, CaseIterable, Identifiable, Sendable {
    /// The game decides (its own windowed or full-screen mode).
    case gameDefault
    /// The game's window fills its screen, without borders (the borderless fix).
    case borderless
    /// Borderless, and in the resizable window the game's picture opens in Mac full screen, in its own Space.
    /// Without the resizable window it's the same as Borderless: a window that covers the whole screen, which
    /// Wine already shows full screen (menu bar and Dock hidden).
    case fullScreen

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gameDefault: "Game default"
        case .borderless: "Fullscreen (Borderless)"
        case .fullScreen: "Fullscreen"
        }
    }

    public static func current(_ g: InstalledGame) -> GameWindowStyle {
        guard g.custom?.borderless == true else { return .gameDefault }
        return g.custom?.macFullScreen == true ? .fullScreen : .borderless
    }

    public static func current(_ s: HostedSettings.Settings) -> GameWindowStyle {
        guard s.borderless == true else { return .gameDefault }
        return s.macFullScreen == true ? .fullScreen : .borderless
    }

    public static func set(_ style: GameWindowStyle, in s: inout HostedSettings.Settings) {
        s.borderless = style == .gameDefault ? nil : true
        s.macFullScreen = style == .fullScreen ? true : nil
    }

    public static func apply(_ style: GameWindowStyle, to game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        let g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        if style != .gameDefault {
            if !CompatibilityFixes.isInstalled(.borderless, for: g) { try await CompatibilityFixes.installReserved(.borderless, for: g, log: log) }
        } else if CompatibilityFixes.isInstalled(.borderless, for: g) {
            try CompatibilityFixes.undoReserved(.borderless, for: g, log: log)
        }
        // Record the choice and rewrite the launcher from it.
        let now = CompatibilityFixes.fresh(g)
        guard var c = now.custom else { if style == .gameDefault { return }; throw NokError("This game has no managed settings.") }
        c.borderless = style == .gameDefault ? nil : true
        c.macFullScreen = style == .fullScreen ? true : nil
        try CustomGames.save(c, to: now)
    }

    /// Older callers: on/off borderless.
    public static func apply(borderless: Bool, to game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        try await apply(borderless ? .borderless : .gameDefault, to: game, log: log)
    }
}
