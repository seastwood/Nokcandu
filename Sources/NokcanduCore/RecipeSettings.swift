import Foundation

/// User choices layered over a shipped recipe. The tested launcher, preparation and disc setup stay intact.
public enum RecipeSettings {
    public struct Settings: Codable, Hashable {
        public var graphics: GraphicsPreset? = nil // nil = exact recipe defaults
        public var program = ""                    // empty = recipe's own launch method
        public var arguments = ""
        public var environment: [String: String] = [:]
        public var microphone = false
        public init() {}
    }
    public static func supports(_ g: InstalledGame) -> Bool {
        g.custom == nil && g.native == nil && g.recipe.map { RecipeCatalog.recipe(id: $0.id) != nil } == true
    }
    static func file(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("recipe-settings.json") }
    public static func load(_ g: InstalledGame) -> Settings {
        (try? Data(contentsOf: file(g))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
    public static func graphics(_ g: InstalledGame) -> GraphicsPreset {
        load(g).graphics ?? (g.recipe?.runtime.renderer == nil ? .compatible : .classic3D)
    }
    static let marker = "# nokcandu-recipe-settings"
    static let invocation = "nokcandu_recipe_wine "
    static let block = #"""
# nokcandu-recipe-settings
NOKCANDU_RECIPE_ARGS=()
NOKCANDU_RECIPE_PROGRAM=''
export NOKCANDU_NO_MICROPHONE=1
[ ! -f "$SUPPORT/nokcandu/recipe-settings.env" ] || . "$SUPPORT/nokcandu/recipe-settings.env"
[ ! -f "$SUPPORT/nokcandu/perf.env" ] || . "$SUPPORT/nokcandu/perf.env"
nokcandu_recipe_wine() {
 local recipe_wine="$1"; shift
 if [ -n "$NOKCANDU_RECIPE_PROGRAM" ]; then
  "$recipe_wine" "$NOKCANDU_RECIPE_PROGRAM" ${NOKCANDU_RECIPE_ARGS[@]+"${NOKCANDU_RECIPE_ARGS[@]}"}
 else
  "$recipe_wine" "$@" ${NOKCANDU_RECIPE_ARGS[@]+"${NOKCANDU_RECIPE_ARGS[@]}"}
 fi
}
# nokcandu-recipe-settings end

"""#
    /// Patch only a recognized template. HelperPatch.strip reverses this exactly for ownership checks.
    static func patch(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let command = lines.lastIndex(where: { $0.hasPrefix(#""$SUPPORT/wine/bin/wine" "#) }),
              let insertion = lines.firstIndex(where: { $0.hasPrefix("export PATH=") }), command > insertion else { return text }
        lines[command] = invocation + lines[command]
        lines.insert(contentsOf: block.components(separatedBy: "\n").dropLast(), at: insertion + 1)
        return lines.joined(separator: "\n")
    }
    static func strip(_ text: String) -> String {
        guard text.contains(block) else { return text }
        return text.replacingOccurrences(of: block, with: "").components(separatedBy: "\n").map {
            $0.hasPrefix(invocation) ? String($0.dropFirst(invocation.count)) : $0
        }.joined(separator: "\n")
    }
    static func environment(_ settings: Settings, recipe: GameRecipe) throws -> String {
        guard settings.environment.keys.allSatisfy(CustomGames.isValidEnvName) else { throw NokError("Environment variable names must contain only letters, numbers and underscores.") }
        var lines: [String] = []
        if let mode = settings.graphics {
            lines.append("unset WINEDLLPATH_D9VK WINEDLLPATH_DXVK WINEDLLPATH_D3DMETAL WINEDLLPATH_DXMT WINEDLLPATH_CNCD CX_D3DMETALPATH DYLD_FALLBACK_FRAMEWORK_PATH CX_APPLEGPTK_LIBD3DSHARED_PATH")
            lines += mode.launcherExports
            // Replace only the renderer rules; keep recipe-required .NET/ICU/runtime overrides.
            let renderers: Set<String> = ["d3d8", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12", "d3d12core", "dxgi", "ddraw", "winemetal"]
            let retained = CompatibilityFixes.overrides(recipe.environment["WINEDLLOVERRIDES"] ?? "").filter { !renderers.contains($0.key) }
            let rules = retained.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            lines.append("export WINEDLLOVERRIDES=" + CustomGames.shellQuote(mode.mergedDLLOverrides(rules)))
        }
        for (key, value) in settings.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=" + CustomGames.shellQuote(value))
        }
        lines.append(GameMicrophone.launcherExports(allowed: settings.microphone))
        lines.append("NOKCANDU_RECIPE_PROGRAM=" + CustomGames.shellQuote(settings.program))
        lines.append("NOKCANDU_RECIPE_ARGS=(" + CustomGames.splitArguments(settings.arguments).map(CustomGames.shellQuote).joined(separator: " ") + ")")
        return lines.joined(separator: "\n") + "\n"
    }
    public static func save(_ settings: Settings, for g: InstalledGame) throws {
        guard supports(g), let recipe = g.recipe, let launcher = g.launcherURL else { throw NokError("This game has no shipped recipe.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit \(g.name) before changing its launch settings.") }
        guard [.original, .nokcanduPatched].contains(DisplayController.launcherState(g)) else {
            throw NokError("The launcher was edited outside Nokcandu, so your changes were kept. Restore the recipe launcher before applying these settings.")
        }
        if !settings.program.isEmpty {
            guard let path = BattleNet.unixPath(settings.program, prefix: g.prefix), FileManager.default.fileExists(atPath: path.path) else {
                throw NokError("Choose a Windows program that exists in this game's Windows environment.")
            }
        }
        if let mode = settings.graphics {
            let layer: String? = switch mode {
            case .classic3D: "d9vk"; case .modern3D: "dxvk3"; case .appleMetal: "d3dmetal"; case .dxmt: "dxmt"; case .classic2D: "cnc_ddraw"; case .compatible: nil
            }
            if let layer, !FileManager.default.fileExists(atPath: g.support.appendingPathComponent("renderer/\(layer)/wine").path) {
                throw NokError("\(mode.title) isn't installed in this game's engine. Choose another graphics mode or install an engine containing that graphics layer in Updates.")
            }
        }
        let env = try environment(settings, recipe: recipe)
        let current = try String(contentsOf: launcher, encoding: .utf8)
        let updated = HelperPatch.add(to: current, recipe: true) ?? current
        guard updated.contains(marker) else { throw NokError("This recipe's launch command isn't recognized; its launcher was kept.") }
        let journal = ChangeJournal(scope: g.journalScope)
        try journal.write(Data(updated.utf8), to: launcher, reason: "Recipe reads user settings")
        try journal.write(Data(env.utf8), to: g.nokcanduState.appendingPathComponent("recipe-settings.env"), reason: "Recipe launch overrides")
        try journal.write(try JSONEncoder().encode(settings), to: file(g), reason: "Recipe user settings")
        if let fresh = GameLibrary.inspect(g.appURL) { try LauncherEntry.ensure(fresh) }
    }
}
