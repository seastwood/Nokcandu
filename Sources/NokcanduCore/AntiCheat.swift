import Foundation

/// Which games use anti-cheat that keeps them from running (or from going online) in Wine.
/// Data: AreWeAntiCheatYet (https://areweanticheatyet.com, MIT), downloaded weekly. Its statuses are
/// about Linux/Steam Deck; on a Mac, Wine has none of Proton's anti-cheat support, so anything with
/// kernel-level anti-cheat is at best risky.
public enum AntiCheat {
    public enum Verdict: String, Sendable { case blocked, risky }

    public struct Warning: Hashable, Sendable {
        public var verdict: Verdict
        public var anticheats: [String]
        public var short: String       // for a list row
        public var detail: String      // for a game page
    }

    static let source = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json")!
    static var file: URL { NokPaths.support.appendingPathComponent("anticheat.json") }
    /// Work fine in Wine (server-side or Valve's own).
    static let harmless: Set<String> = ["VAC", "FairFight"]
    /// Run as Windows kernel drivers — never in Wine.
    static let kernel: Set<String> = ["Easy Anti-Cheat", "BattlEye", "Vanguard", "EA anticheat", "Ricochet", "FACEIT", "ESEA",
                                      "nProtect GameGuard", "XIGNCODE3", "Anti-Cheat Expert", "Nexon Game Security", "mhyprot2",
                                      "Denuvo Anti-Cheat", "X-Trap", "Hyperion", "NetEase Anti-Cheat Expert"]

    struct Entry { var name: String; var status: String; var anticheats: [String] }
    struct Index { var steam: [String: Entry] = [:]; var epic: [String: Entry] = [:]; var name: [String: Entry] = [:] }

    private static let cache = Locked<Index?>(nil)

    /// Downloads the list if it's missing or a week old. Quiet on failure (the old copy stays).
    public static func refreshIfStale() async {
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 7 * 86400 else { return }
        guard let (d, r) = try? await URLSession.shared.data(from: source), (r as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONSerialization.jsonObject(with: d)) is [[String: Any]] else { return }
        try? NokPaths.ensure(NokPaths.support)
        try? d.write(to: file, options: .atomic)
        cache.value = nil
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(String.init).joined()
    }

    static func index() -> Index {
        if let i = cache.value { return i }
        var i = Index()
        if let d = try? Data(contentsOf: file), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            for g in arr {
                guard let name = g["name"] as? String else { continue }
                let e = Entry(name: name, status: g["status"] as? String ?? "", anticheats: g["anticheats"] as? [String] ?? [])
                i.name[normalized(name)] = e
                let ids = g["storeIds"] as? [String: Any] ?? [:]
                if let s = ids["steam"] as? String { i.steam[s] = e }
                if let ep = ids["epic"] as? [String: Any], let ns = ep["namespace"] as? String { i.epic[ns] = e }
            }
        }
        cache.value = i
        return i
    }

    public static func warning(steamAppID: Int? = nil, epicNamespace: String? = nil, name: String? = nil) -> Warning? {
        let i = index()
        let e = steamAppID.flatMap { i.steam[String($0)] } ?? epicNamespace.flatMap { i.epic[$0] }
            ?? name.flatMap { i.name[normalized($0)] }
        guard let e else { return nil }
        return warning(e)
    }

    /// Older, server-side or opt-in systems: only some online servers use them.
    static let serverOptional: Set<String> = ["PunkBuster", "ESL Wire", "Arkos", "SARD"]

    /// Careful wording: the data is about Linux/Steam Deck, it's about online play, and Mac results vary
    /// (Wine on a Mac has run games with Warden or PunkBuster online). Only kernel-level anti-cheat — which
    /// can't run in Wine at all — gets a real warning; other anti-cheat gets a note only if reported broken.
    static func warning(_ e: Entry) -> Warning? {
        let relevant = e.anticheats.filter { !harmless.contains($0) }
        guard !relevant.isEmpty else { return nil }
        let list = relevant.joined(separator: ", ")
        let kernelOnes = relevant.filter(kernel.contains)
        if kernelOnes.isEmpty {
            guard e.status == "Broken" || e.status == "Denied" else { return nil }
            return Warning(verdict: .risky, anticheats: relevant, short: "Some online play may use \(list)",
                           detail: "\(e.name) can use \(list) online. Linux players report problems with it, but results in Wine on a Mac vary. Single-player, LAN and servers without it aren't affected — worth trying.")
        }
        let k = kernelOnes.joined(separator: ", ")
        if e.status == "Denied" {
            return Warning(verdict: .blocked, anticheats: kernelOnes, short: "Online play likely blocked: \(k)",
                           detail: "\(e.name) uses kernel-level anti-cheat (\(k)), and its developer doesn't allow it on Linux or Steam Deck. Online play will most likely be refused in Wine too. Offline or single-player modes, if the game has them, may still work.")
        }
        return Warning(verdict: .risky, anticheats: kernelOnes, short: "Online play may be blocked: \(k)",
                       detail: "\(e.name) uses kernel-level anti-cheat (\(k)), which can't run inside Wine, so online play may be refused on a Mac. Offline or single-player modes usually aren't affected — worth trying.")
    }

    /// For an installed game: by its Steam app, store link, or name.
    public static func warning(for g: InstalledGame) -> Warning? {
        warning(steamAppID: g.custom?.steamAppID, epicNamespace: nil, name: LibraryOrganizer.canonicalName(g))
    }
}
