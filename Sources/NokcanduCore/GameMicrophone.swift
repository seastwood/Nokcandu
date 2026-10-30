import Foundation

/// Settings ▸ Microphone: per game. Off (the default) hides audio inputs from the game (Nokcandu's helper
/// library answers "no input streams"), so it never opens one and macOS never asks for microphone permission.
public enum GameMicrophone {
    /// Games whose launcher Nokcandu writes (its own games and EA/Ubisoft games added to Nokcandu).
    public static func supported(_ g: InstalledGame) -> Bool { g.native == nil && (g.custom != nil || g.hosted?.exe != nil) }

    public static func isOn(_ g: InstalledGame) -> Bool {
        if let c = g.custom { return c.microphone == true }
        if g.hosted != nil { return HostedSettings.load(g).microphone == true }
        return true
    }

    public static func set(_ on: Bool, for g: InstalledGame) throws {
        if var c = g.custom {
            c.microphone = on ? true : nil
            try CustomGames.save(c, to: g)
        } else if g.hosted != nil {
            var s = HostedSettings.load(g)
            s.microphone = on ? true : nil
            try HostedSettings.save(s, for: g)
        }
    }
}
