import Foundation
import NokcanduCore

@main struct SavedSettingsTool {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 5, args[3] == "--state-root" { PendingSettings.stateRootOverride = URL(fileURLWithPath: args[4]) }
        guard (args.count == 3 || args.count == 5 && args[3] == "--state-root"), (args[1] == "--apply" || args[1] == "--status"), let game = GameLibrary.inspect(URL(fileURLWithPath: args[2]).standardizedFileURL) else { exit(64) }
        if args[1] == "--status" { print(PendingSettings.activity(for: game)); return }
        if let root = PendingSettings.resourceRoot(for: game) { NokPaths.resourceOverride = root }
        do { _ = try await PendingSettings.apply(for: game, waitForApplication: true) { fputs($0 + "\n", stderr) } }
        catch { fputs("Saved settings could not be applied: " + error.localizedDescription + "\n", stderr); exit(1) }
    }
}
