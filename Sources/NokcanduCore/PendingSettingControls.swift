import Foundation

extension PendingSettings {
    /// Visible control titles affected by desired values, compared with persisted values
    /// rather than the UI's desired-value preview. Microphone is live and excluded.
    public static func controlTitles(for game: InstalledGame) -> Set<String> {
        let actual = GameLibrary.inspect(game.appURL) ?? game
        var titles = Set<String>()
        func add(_ values: String...) { for value in values { titles.insert(value.lowercased()) } }
        func performance(_ desired: Performance.Settings) {
            let old = Performance.settings(for: actual)
            if desired.fpsCounter != old.fpsCounter { add("Show FPS counter") }
            if desired.lowLatency != old.lowLatency { add("Low-latency mode") }
            if desired.vsync != old.vsync { add("Vsync") }
            if desired.fpsLimit != old.fpsLimit { add("Frame limit") }
            if desired.hud != old.hud || desired.hudSize != old.hudSize { add("Counter style") }
        }
        for entry in entries(for: actual) {
            // Wine/performance/audio belong to the whole shared environment.
            switch entry.change {
            case .wine: add("Wine version")
            case .performance(let desired): performance(desired)
            case .audioBuffer: add("Audio buffer")
            default:
                guard entry.identity == identity(actual) else { continue }
                switch entry.change {
                case .graphics: add("Graphics")
                case .lowLatency: add("Low-latency aiming", "Launch options")
                case .frameCap: add("Game frame cap", "Launch options")
                case .display: add("Mac screen resolution")
                case .windowStyle: add("Window style")
                case .nativeFrame: add("IPX frame type")
                case .nativeAdapter: add("IPX LAN connection")
                case .compatibility(let fix, _): add(fix.title)
                case .cinematic: add("Video and music playback")
                case .bc2: add("Graphics", "Game resolution", "Window style")
                case .custom(let desired, _, _):
                    if desired.graphics != actual.custom?.graphics { add("Graphics") }
                    if desired.exe != actual.custom?.exe { add("Program") }
                    if desired.name != actual.custom?.name { add("Name") }
                    if desired.arguments != actual.custom?.arguments { add("Launch options") }
                    if desired.environment != actual.custom?.environment { add("Extra settings", "Advanced: environment variables") }
                case .recipe(let desired):
                    let old = RecipeSettings.load(actual)
                    if desired.graphics != old.graphics { add("Graphics") }
                    if desired.program != old.program { add("Program") }
                    if desired.arguments != old.arguments { add("Launch options") }
                    if desired.environment != old.environment { add("Extra settings", "Advanced environment variables") }
                case .hosted(let desired):
                    let old = HostedSettings.load(actual)
                    if desired.graphics != old.graphics { add("Graphics") }
                    if desired.arguments != old.arguments { add("Launch options") }
                    if desired.environment != old.environment { add("Extra settings", "Advanced environment variables") }
                    if desired.borderless != old.borderless || desired.macFullScreen != old.macFullScreen { add("Window style") }
                default: break
                }
            }
        }
        if WindowedPresentation.needsIdleApply(for: actual), let host = WineTools.hostContents(for: actual),
           (WindowedPresentation.setting(for: actual) == nil) != (WindowedPresentation.applied(host: host) == nil) {
            add("Play in a resizable window", "Virtual screen")
        }
        return titles
    }
}
