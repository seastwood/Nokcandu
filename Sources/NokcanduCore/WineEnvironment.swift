import Foundation

/// The environment every Wine program from Nokcandu gets: the one Sikarugir's own launcher gives its engines.
///
/// Wine's Unix media modules load GStreamer dylibs by @rpath. The framework's lib directory is not the app's
/// Frameworks directory; omitting it breaks Media Foundation before decoder selection (wg_parser_create fails,
/// misleadingly as E_OUTOFMEMORY). GStreamer finds its plugins (video and audio decoders) through GST_PLUGIN_PATH.
///
/// From Sikarugir's launcher:
/// - SikarugirAppWine11=1: Sikarugir's Wine 11 engines can't start any program without it ("failed to start wineboot").
/// - ROSETTA_ADVERTISE_AVX=1: Rosetta tells games the CPU has AVX/AVX2 (it translates them), so games that require
///   AVX start instead of refusing or crashing.
/// - DOTNET_EnableWriteXorExecute=0: .NET programs (launchers, tools, some games) run faster and without
///   W^X failures under Rosetta.
/// - MVK_CONFIG_RESUME_LOST_DEVICE=1, MVK_CONFIG_FAST_MATH_ENABLED=0: MoltenVK (under DXVK) recovers a lost GPU
///   device instead of ending the game, and keeps exact shader math.
/// - CX_FWD_COMPAT_GL_CTX=1: OpenGL games asking for modern contexts get forward-compatible ones macOS supports.
/// - CX_ROOT: where the engine lives, for D3DMetal. WINEBOOT_HIDE_DIALOG=1: no "updating Wine" window.
/// - QMLSCENE_DEVICE=softwarecontext: Qt-based launchers draw reliably.
/// - SDL_JOYSTICK_MFI=0: controllers reach games once, through their USB/Bluetooth driver (not twice).
/// - DXVK_SHADER_CACHE_PATH: one shader cache for every game, the same folder Sikarugir uses, so shaders a game
///   compiled once are reused instead of stuttering again.
/// - BRIDGE_RPC_PATH: where the Mac Discord app's socket is, for the Discord bridge (DiscordBridge).
public enum WineEnvironment {
    static let mediaSuffix = "/Frameworks/GStreamer.framework/Versions/1.0/lib"
    static let pluginSuffix = "/Frameworks/GStreamer.framework/Libraries/gstreamer-1.0"
    /// Variables every engine gets, whatever the game.
    public static let engineVariables: [(String, String)] = [
        ("SikarugirAppWine11", "1"), ("ROSETTA_ADVERTISE_AVX", "1"), ("DOTNET_EnableWriteXorExecute", "0"),
        ("MVK_CONFIG_RESUME_LOST_DEVICE", "1"), ("MVK_CONFIG_FAST_MATH_ENABLED", "0"), ("CX_FWD_COMPAT_GL_CTX", "1"),
        ("WINEBOOT_HIDE_DIALOG", "1"), ("QMLSCENE_DEVICE", "softwarecontext"), ("SDL_JOYSTICK_MFI", "0"),
    ]

    public static func libraryPath(contents:URL) -> String {
        contents.appendingPathComponent("Frameworks").path + ":" + contents.path + mediaSuffix + ":/usr/lib"
    }
    /// Adds the library path and the engine variables to an environment.
    public static func apply(contents: URL, to env: inout [String: String]) {
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath(contents: contents)
        env["GST_PLUGIN_PATH"] = contents.path + pluginSuffix
        env["CX_ROOT"] = contents.appendingPathComponent("SharedSupport/wine").path
        env["DXVK_SHADER_CACHE_PATH"] = NSHomeDirectory() + "/.cache/dxvk"
        // The Discord bridge (if installed) finds the Mac Discord app's socket here.
        if let t = ProcessInfo.processInfo.environment["TMPDIR"] { env["BRIDGE_RPC_PATH"] = t.hasSuffix("/") ? String(t.dropLast()) : t }
        for (k, v) in engineVariables { env[k] = v }
    }

    /// Launcher scripts: each version of the managed export block, oldest first. A script carrying an older one is
    /// upgraded to the current one; recipe fingerprints compare the oldest.
    static func legacyLine(_ v: String) -> String { "export DYLD_FALLBACK_LIBRARY_PATH=\"$\(v)/Frameworks:/usr/lib\"" }
    static func mediaLine(_ v: String) -> String { "export DYLD_FALLBACK_LIBRARY_PATH=\"$\(v)/Frameworks:$\(v)\(mediaSuffix):/usr/lib\"" }
    static func versions(_ v: String) -> [String] {
        [legacyLine(v), mediaLine(v), mediaLine(v) + "\nexport SikarugirAppWine11=1", exportLineV3(v), exportLineV4(v), exportLine(v)]
    }
    static func exportLineV3(_ v: String) -> String {
        mediaLine(v)
            + "\nexport GST_PLUGIN_PATH=\"$\(v)\(pluginSuffix)\" CX_ROOT=\"$\(v)/SharedSupport/wine\""
            + "\nexport SikarugirAppWine11=1 ROSETTA_ADVERTISE_AVX=1 DOTNET_EnableWriteXorExecute=0 MVK_CONFIG_RESUME_LOST_DEVICE=1 MVK_CONFIG_FAST_MATH_ENABLED=0 CX_FWD_COMPAT_GL_CTX=1 WINEBOOT_HIDE_DIALOG=1 QMLSCENE_DEVICE=softwarecontext"
    }
    static func exportLineV4(_ v: String) -> String {
        mediaLine(v)
            + "\nexport GST_PLUGIN_PATH=\"$\(v)\(pluginSuffix)\" CX_ROOT=\"$\(v)/SharedSupport/wine\" DXVK_SHADER_CACHE_PATH=\"$HOME/.cache/dxvk\""
            + "\nexport SikarugirAppWine11=1 ROSETTA_ADVERTISE_AVX=1 DOTNET_EnableWriteXorExecute=0 MVK_CONFIG_RESUME_LOST_DEVICE=1 MVK_CONFIG_FAST_MATH_ENABLED=0 CX_FWD_COMPAT_GL_CTX=1 WINEBOOT_HIDE_DIALOG=1 QMLSCENE_DEVICE=softwarecontext SDL_JOYSTICK_MFI=0"
    }
    static func exportLine(_ variable:String = "CONTENTS") -> String {
        let v = variable
        return mediaLine(v)
            + "\nexport GST_PLUGIN_PATH=\"$\(v)\(pluginSuffix)\" CX_ROOT=\"$\(v)/SharedSupport/wine\" DXVK_SHADER_CACHE_PATH=\"$HOME/.cache/dxvk\" BRIDGE_RPC_PATH=\"${TMPDIR%/}\""
            + "\nexport " + engineVariables.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
    static func upgradeExports(_ text:String) -> String {
        var result=text
        for v in ["CONTENTS","HC"] where !result.contains(exportLine(v)) {
            // Newest older block first (each contains the ones before it).
            for old in versions(v).dropLast().reversed() where result.contains(old) {
                result=result.replacingOccurrences(of:old,with:exportLine(v)); break
            }
        }
        return result
    }
    /// Normalize only this managed addition when recognizing pinned legacy recipe scripts.
    /// This does not authorize replacing manually edited launchers.
    static func originalExports(_ text:String) -> String {
        var result=text
        for v in ["CONTENTS","HC"] {
            for block in versions(v).dropFirst().reversed() { result=result.replacingOccurrences(of:block,with:legacyLine(v)) }
        }
        return result
    }
}
