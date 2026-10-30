import Foundation

/// The environment every Wine program from Nokcandu gets.
///
/// Wine's Unix media modules load GStreamer dylibs by @rpath. The framework's lib directory is not the app's
/// Frameworks directory; omitting it breaks Media Foundation before decoder selection (wg_parser_create fails,
/// misleadingly as E_OUTOFMEMORY).
///
/// Sikarugir's Wine 11 engines only start Windows programs when `SikarugirAppWine11=1` is set (Sikarugir's own
/// launcher sets it); without it every program fails at "failed to start wineboot". Older engines ignore it.
public enum WineEnvironment {
    static let mediaSuffix = "/Frameworks/GStreamer.framework/Versions/1.0/lib"
    /// Variables every engine gets, whatever the game (engine requirements, not tuning).
    public static let engineVariables: [String: String] = ["SikarugirAppWine11": "1"]

    public static func libraryPath(contents:URL) -> String {
        contents.appendingPathComponent("Frameworks").path + ":" + contents.path + mediaSuffix + ":/usr/lib"
    }
    /// Adds the library path and the engine variables to an environment.
    public static func apply(contents: URL, to env: inout [String: String]) {
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath(contents: contents)
        for (k, v) in engineVariables { env[k] = v }
    }

    /// Launcher scripts, each version of the managed export block (oldest first).
    static func legacyLine(_ v: String) -> String { "export DYLD_FALLBACK_LIBRARY_PATH=\"$\(v)/Frameworks:/usr/lib\"" }
    static func mediaLine(_ v: String) -> String { "export DYLD_FALLBACK_LIBRARY_PATH=\"$\(v)/Frameworks:$\(v)\(mediaSuffix):/usr/lib\"" }
    static func exportLine(_ variable:String = "CONTENTS") -> String {
        mediaLine(variable) + "\nexport SikarugirAppWine11=1"
    }
    static func upgradeExports(_ text:String) -> String {
        var result=text
        for v in ["CONTENTS","HC"] where !result.contains(exportLine(v)) {
            if result.contains(mediaLine(v)) { result=result.replacingOccurrences(of:mediaLine(v),with:exportLine(v)) }
            else { result=result.replacingOccurrences(of:legacyLine(v),with:exportLine(v)) }
        }
        return result
    }
    /// Normalize only this managed addition when recognizing pinned legacy recipe scripts.
    /// This does not authorize replacing manually edited launchers.
    static func originalExports(_ text:String) -> String {
        var result=text
        for v in ["CONTENTS","HC"] {
            result=result.replacingOccurrences(of:exportLine(v),with:legacyLine(v))
            result=result.replacingOccurrences(of:mediaLine(v),with:legacyLine(v))
        }
        return result
    }
}
