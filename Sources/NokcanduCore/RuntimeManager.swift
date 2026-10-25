import Foundation

/// Shared, versioned runtime cache: Wine engine + wrapper frameworks + renderer packages.
/// Per-game prefixes are never stored here. Games get APFS clones of the runtime, so a new
/// app costs almost no extra disk until files diverge.
public struct RuntimeManifest: Codable {
    public var id: String
    public var engine: String
    public var wineVersion: String
    public var template: String
    public var importedFrom: String
    public var importedAt: Date
    public var verifiedHashes: [String: String]
    public var licenses: [String]
    /// Result of running a Windows program with this runtime in a scratch environment (nil = not tested).
    public var selfTest: Bool? = nil
}

public enum RuntimeManager {
    /// Parts of an app's Contents that make up the runtime (never prefix, game files, logs, or saves).
    public static let components = [
        "Frameworks",
        "SharedSupport/wine",
        "SharedSupport/renderer",
        "Resources/vulkan",
    ]

    public static let licenseRecords = [
        "Wine (Sikarugir engine WS12WineSikarugir10.0_8): LGPL-2.1-or-later — https://github.com/Sikarugir-App/Engines/releases/tag/v1.0",
        "Sikarugir wrapper template 1.0.24 frameworks: see the Sikarugir project licenses",
        "DXVK-Sikarugir 3.1.1-async (renderer/d9vk): zlib license",
        "Mesa KosmicKrisp Vulkan driver: MIT license — https://docs.mesa3d.org/drivers/kosmickrisp.html",
        "MoltenVK (libMVK, unused by the validated recipe): Apache-2.0",
    ]

    public static func folder(for id: String) -> URL { NokPaths.runtimes.appendingPathComponent(id, isDirectory: true) }

    public static func manifest(for id: String) -> RuntimeManifest? {
        let url = folder(for: id).appendingPathComponent("manifest.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? ChangeJournal.decoder.decode(RuntimeManifest.self, from: d)
    }

    public static func isCached(_ spec: RuntimeSpec) -> Bool {
        guard manifest(for: spec.id) != nil else { return false }
        return components.allSatisfy { FileManager.default.fileExists(atPath: folder(for: spec.id).appendingPathComponent("Contents/\($0)").path) }
    }

    /// Picks an installed game whose runtime is the requested engine and has every pinned file intact.
    public static func importCandidate(for recipe: GameRecipe, in games: [InstalledGame]) -> InstalledGame? {
        let pins = runtimePins(recipe)
        return games.first { g in
            g.wineVersion == recipe.runtime.wineVersionString &&
            components.allSatisfy { FileManager.default.fileExists(atPath: g.contents.appendingPathComponent($0).path) } &&
            pins.allSatisfy { (rel, sha) in (try? Hashing.sha256(file: g.contents.appendingPathComponent(rel))) == sha }
        }
    }

    static func runtimePins(_ recipe: GameRecipe) -> [String: String] {
        recipe.pinnedHashes.filter { rel, _ in components.contains { rel.hasPrefix($0 + "/") } }
    }

    /// Imports the runtime from a working app into the cache (APFS clone) and verifies pinned hashes.
    public static func importRuntime(for recipe: GameRecipe, from app: InstalledGame, log: (String) -> Void) throws {
        let dest = folder(for: recipe.runtime.id)
        let staging = NokPaths.runtimes.appendingPathComponent(".\(recipe.runtime.id)-incoming")
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        for c in components {
            log("Copying \(c) from \(app.name)…")
            try fm.cloneItem(at: app.contents.appendingPathComponent(c), to: staging.appendingPathComponent("Contents/\(c)"))
        }
        var verified: [String: String] = [:]
        for (rel, want) in runtimePins(recipe) {
            let got = try Hashing.sha256(file: staging.appendingPathComponent("Contents/\(rel)"))
            guard got == want else {
                try? fm.removeItem(at: staging)
                throw NokError("Runtime file \(rel) does not match the validated build; import stopped.")
            }
            verified[rel] = got
        }
        let wineVersion = (try? String(contentsOf: staging.appendingPathComponent("Contents/SharedSupport/wine/version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard wineVersion == recipe.runtime.wineVersionString else {
            try? fm.removeItem(at: staging)
            throw NokError("Engine version \(wineVersion) is not \(recipe.runtime.wineVersionString).")
        }
        let manifest = RuntimeManifest(id: recipe.runtime.id, engine: recipe.runtime.engine, wineVersion: wineVersion,
                                       template: recipe.runtime.template, importedFrom: app.appURL.path, importedAt: Date(),
                                       verifiedHashes: verified, licenses: licenseRecords)
        try ChangeJournal.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        try fm.moveItem(at: staging, to: dest)
        log("Runtime \(recipe.runtime.id) cached and verified.")
    }

    /// Clones the cached runtime into a new app's Contents.
    public static func install(_ spec: RuntimeSpec, into contents: URL) throws {
        let src = folder(for: spec.id).appendingPathComponent("Contents")
        for c in components {
            let dst = contents.appendingPathComponent(c)
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            try FileManager.default.cloneItem(at: src.appendingPathComponent(c), to: dst)
        }
    }
}
