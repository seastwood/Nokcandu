import Foundation

/// Explicit Wine choices. A default is copied into a new install, never applied to existing games.
public enum WineSelection {
    public static let inputKey = "wine.engine"
    static let preferenceKey = "defaultWineEngine"
    public static let minimum = EngineVersion(major: 10, minor: 0, revision: 0)
    public static func parse(_ tag: String) -> EngineVersion? {
        guard let version = EngineVersion(assetName: "WS12WineSikarugir\(tag).tar.xz"), version >= minimum else { return nil }
        return version
    }
    public static func defaultEngine(in defaults: UserDefaults = .standard) -> EngineVersion {
        defaults.string(forKey: preferenceKey).flatMap(parse) ?? .tested
    }
    public static func setDefault(_ engine: EngineVersion, in defaults: UserDefaults = .standard) throws {
        guard engine >= minimum else { throw NokError("Wine 10.0 is the earliest supported version.") }
        defaults.set(engine.tag, forKey: preferenceKey)
    }
    public static func versions(catalog: UpdateCatalog?, cached: [RuntimeManifest]) -> [EngineVersion] {
        let released = (catalog?.engines ?? []).filter { $0.sha256?.count == 64 }.compactMap { EngineVersion(assetName: $0.name) }
        let local = cached.filter { $0.selfTest != false }.compactMap { EngineVersion(versionString: $0.wineVersion) }
        return Set(released + local + [.tested]).filter { $0 >= minimum }.sorted(by: >)
    }
    public static func engine(for state: InstallState) throws -> EngineVersion {
        // Old unfinished installs keep their original engine when a default changes.
        guard let tag = state.inputs[inputKey] else { return .tested }
        guard let engine = parse(tag) else { throw NokError("The saved Wine version is not supported. Choose Wine 10.0 or newer before preparing this installation.") }
        return engine
    }
    static func freeze(_ state: inout InstallState, choice: EngineVersion?, defaults: UserDefaults = .standard) throws {
        let engine: EngineVersion
        if let choice { engine = choice }
        else if state.inputs[inputKey] != nil { engine = try self.engine(for: state) }
        else { engine = defaultEngine(in: defaults) }
        guard engine >= minimum else { throw NokError("Wine 10.0 is the earliest supported version.") }
        state.inputs[inputKey] = engine.tag
    }
    public static func spec(for engine: EngineVersion) -> RuntimeSpec {
        var spec = RecipeCatalog.sikarugirWine10
        spec.id = RuntimeManager.runtimeID(engine: engine, template: .tested)
        spec.engine = engine.engineName; spec.wineVersionString = engine.versionString
        return spec
    }
    /// The verified original wrapper/graphics template stays fixed; only Wine is selected here.
    public static func prepare(_ engine: EngineVersion, catalog supplied: UpdateCatalog? = nil,
                               log: @escaping @Sendable (String) -> Void) async throws -> String {
        guard engine >= minimum else { throw NokError("Wine 10.0 is the earliest supported version.") }
        let spec = spec(for: engine)
        guard !EngineSelfTests.failed(spec.id) else { throw NokError("\(engine) failed the Windows startup check on this Mac and cannot be selected.") }
        if engine == .tested, RuntimeManager.isCached(RecipeCatalog.sikarugirWine10) { return spec.id }
        var catalog: UpdateCatalog
        if let supplied { catalog = supplied }
        else if let cached = Updates.cached(), cached.engine(engine) != nil { catalog = cached }
        else if RuntimeManager.isCached(id: spec.id) {
            catalog = UpdateCatalog(checkedAt: Date(), engines: [], templates: [], lav: nil, nativeEngines: [])
        } else if engine == .tested {
            catalog = UpdateCatalog(checkedAt: Date(), engines: [], templates: [], lav: nil, nativeEngines: [])
        } else { catalog = try await Updates.check() }
        if catalog.engine(.tested) == nil { catalog.engines.append(Setup.testedEngine) }
        if catalog.template(.tested) == nil { catalog.templates.append(Setup.testedTemplate) }
        return try await RuntimeManager.build(engine: engine, template: .tested, catalog: catalog, log: log)
    }
    public static func host(for game: InstalledGame, in library: [InstalledGame]) -> InstalledGame? {
        guard let contents = WineTools.hostContents(for: game) else { return nil }
        if contents == game.contents { return game }
        return library.first { $0.contents.standardizedFileURL == contents.standardizedFileURL }
            ?? GameLibrary.inspect(contents.deletingLastPathComponent())
    }
    public static func incompatibility(host: InstalledGame, target: EngineVersion, games: [InstalledGame]) -> String? {
        let peers = games.filter { WineTools.hostContents(for: $0) == host.contents }
        if target.major != 11 || target.minor != 0,
           ([host] + peers).contains(where: { $0.custom?.environment?[NativeIPXNetworking.flag] == "1" }) {
            return "Native IPX is enabled in this Windows environment and requires Wine 11.0. Turn Native IPX off before choosing \(target)."
        }
        return nil
    }
    static func protectedRuntimeIDs(defaultEngine: EngineVersion, installs: [InstallState]) -> Set<String> {
        Set([spec(for: defaultEngine).id, RecipeCatalog.sikarugirWine10.id])
            .union(installs.filter { $0.finishedAt == nil }.compactMap { try? engine(for: $0) }.map { spec(for: $0).id })
    }
    static func recordInstalled(_ spec: RuntimeSpec, contents: URL) throws {
        guard spec.id != RecipeCatalog.sikarugirWine10.id else { return }
        let state = EngineUpdate.State(runtimeID: spec.id, engine: spec.wineVersionString, previousEngine: spec.wineVersionString,
                                       previousRuntimeID: spec.id, appliedAt: Date(), status: .kept)
        try NokPaths.ensure(EngineUpdate.stateURL(contents).deletingLastPathComponent())
        try ChangeJournal.encoder.encode(state).write(to: EngineUpdate.stateURL(contents), options: .atomic)
    }
}
