import Foundation

/// Recognizes common failures in a game's last launch log and suggests a graphics mode that avoids them.
public struct GraphicsHint: Equatable {
    public var title: String
    public var detail: String
    public var evidence: String
    public var suggested: [GraphicsPreset]
    /// Launch options that avoid the problem (added to the game's options), if any.
    public var addArguments: String? = nil
}

public enum CrashHints {
    struct Rule { var needles: [String]; var title: String; var detail: String; var suggested: [GraphicsPreset]; var arguments: String? = nil }

    /// Chromium-based launchers (Battle.net, EA app, …) draw their own window with a software renderer this way;
    /// games they start still use the graphics mode. This is what Battle.net's own installer passes under Wine.
    public static let browserSoftwareArgs = "--in-process-gpu --use-gl=swiftshader"

    static let rules: [Rule] = [
        Rule(needles: ["GPU process isn't usable", "Exiting GPU process due to errors during initialization"],
             title: "The app's built-in browser couldn't start its graphics",
             detail: "Launchers like Battle.net draw their window with a built-in web engine. Letting that engine draw in software fixes it (your games still use the graphics mode below).",
             suggested: [], arguments: browserSoftwareArgs),
        Rule(needles: ["D3D12CreateDevice", "err:d3d12", "vkd3d"],
             title: "The game needs DirectX 12",
             detail: "Switch graphics to Apple Metal.",
             suggested: [.appleMetal]),
        Rule(needles: ["DXGI_ERROR_UNSUPPORTED", "D3D11CreateDevice failed", "err:d3d11"],
             title: "DirectX 11 didn't start",
             detail: "Try Newer 3D, or Apple Metal for 64-bit games.",
             suggested: [.modern3D, .appleMetal]),
    ]

    public static func diagnose(_ g: InstalledGame) -> GraphicsHint? {
        guard let c = g.custom, !g.usesSharedSteam,
              let tail = tailOfFile(g.logs.appendingPathComponent("launch.log"), maxLines: 400) else { return nil }
        for r in rules {
            guard let needle = r.needles.first(where: { tail.contains($0) }) else { continue }
            let suggested = r.suggested.filter { $0 != c.graphics && !($0 == .appleMetal && c.is64Bit == false) }
            let args = r.arguments.flatMap { c.arguments.contains($0) ? nil : $0 }
            guard !suggested.isEmpty || args != nil else { continue }
            let line = tail.components(separatedBy: .newlines).last { $0.contains(needle) } ?? needle
            return GraphicsHint(title: r.title, detail: r.detail, evidence: line.trimmingCharacters(in: .whitespaces), suggested: suggested, addArguments: args)
        }
        return nil
    }
}
