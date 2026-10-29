import Foundation

/// Wine's Unix media modules load GStreamer dylibs by @rpath. The framework's lib
/// directory is not the app's Frameworks directory; omitting it breaks Media Foundation
/// before decoder selection (wg_parser_create fails, misleadingly as E_OUTOFMEMORY).
public enum WineEnvironment {
    static let mediaSuffix = "/Frameworks/GStreamer.framework/Versions/1.0/lib"
    public static func libraryPath(contents:URL) -> String {
        contents.appendingPathComponent("Frameworks").path + ":" + contents.path + mediaSuffix + ":/usr/lib"
    }
    static func exportLine(_ variable:String = "CONTENTS") -> String {
        "export DYLD_FALLBACK_LIBRARY_PATH=\"$\(variable)/Frameworks:$\(variable)\(mediaSuffix):/usr/lib\""
    }
    static func upgradeExports(_ text:String) -> String {
        var result=text
        for variable in ["CONTENTS","HC"] {
            result=result.replacingOccurrences(of:"export DYLD_FALLBACK_LIBRARY_PATH=\"$\(variable)/Frameworks:/usr/lib\"",with:exportLine(variable))
        }
        return result
    }
    /// Normalize only this managed addition when recognizing pinned legacy recipe scripts.
    /// This does not authorize replacing manually edited launchers.
    static func originalExports(_ text:String) -> String {
        var result=text
        for variable in ["CONTENTS","HC"] {
            result=result.replacingOccurrences(of:exportLine(variable),with:"export DYLD_FALLBACK_LIBRARY_PATH=\"$\(variable)/Frameworks:/usr/lib\"")
        }
        return result
    }
}
