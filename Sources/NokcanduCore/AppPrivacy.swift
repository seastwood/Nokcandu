import Foundation

/// macOS only asks for microphone access when the app that starts a program declares why it wants it.
/// Without this key in Info.plist, Wine's audio input is silently denied (devices show, but no sound).
public enum AppPrivacy {
    public static let keys: [String: Any] = [
        "NSMicrophoneUsageDescription": "Games and Steam can use your microphone for voice chat.",
    ]

    /// Adds the privacy keys to apps Nokcandu created, if missing. Returns true when an app changed.
    @discardableResult
    public static func ensure(_ app: URL) -> Bool {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard var plist = NSDictionary(contentsOf: url) as? [String: Any], plist["NokcanduRecipe"] != nil else { return false }
        var changed = false
        for (k, v) in keys where plist[k] == nil { plist[k] = v; changed = true }
        guard changed, let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? d.write(to: url, options: .atomic)) != nil else { return false }
        _ = try? Shell.run("/usr/bin/touch", [app.path])          // let macOS notice the new Info.plist
        return true
    }

    public static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
