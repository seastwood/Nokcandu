import Foundation
import NokcanduCore

@main struct SavedSettingsTool {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--replace-app" {
            do {
                let plan = try JSONDecoder().decode(AppRollback.Plan.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                try AppRollback.replace(plan)
                try? FileManager.default.removeItem(at: plan.archiveRoot.appendingPathComponent("last-failure.txt"))
                try? Data("Nokcandu was replaced successfully.".utf8).write(to: plan.archiveRoot.appendingPathComponent("last-result.txt"), options: .atomic)
                print("Nokcandu was replaced successfully.")
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                // Return to the existing UI after a refused/failed replacement; the result file stays available.
                if let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])), let plan = try? JSONDecoder().decode(AppRollback.Plan.self, from: data) {
                    try? Data(error.localizedDescription.utf8).write(to: plan.archiveRoot.appendingPathComponent("last-result.txt"), options: .atomic)
                    try? Data(error.localizedDescription.utf8).write(to: plan.archiveRoot.appendingPathComponent("last-failure.txt"), options: .atomic)
                    _ = try? Shell.run("/usr/bin/open", [plan.current.path])
                }
                exit(1)
            }
            return
        }
        if (args.count == 4 || args.count == 6 && args[4] == "--archive-root"), (args[1] == "--restore-app" || args[1] == "--install-app") {
            AppRollback.recoveryHelperOverride = URL(fileURLWithPath: args[0]).standardizedFileURL
            do {
                let root = args.count == 6 ? URL(fileURLWithPath: args[5]) : AppRollback.root
                try AppRollback.recover(source: URL(fileURLWithPath: args[2]), current: URL(fileURLWithPath: args[3]), archiveRoot: root, relaunch: args[1] == "--restore-app")
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if args.count == 3, args[1] == "--keep-app" {
            AppRollback.recoveryHelperOverride = URL(fileURLWithPath: args[0]).standardizedFileURL
            do { print(try AppRollback.archive(URL(fileURLWithPath: args[2])).folder().path) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if args.count == 5, args[3] == "--state-root" { PendingSettings.stateRootOverride = URL(fileURLWithPath: args[4]) }
        guard (args.count == 3 || args.count == 5 && args[3] == "--state-root"), (args[1] == "--apply" || args[1] == "--status"), let game = GameLibrary.inspect(URL(fileURLWithPath: args[2]).standardizedFileURL) else { exit(64) }
        if args[1] == "--status" { print(PendingSettings.activity(for: game)); return }
        if let root = PendingSettings.resourceRoot(for: game) { NokPaths.resourceOverride = root }
        do { _ = try await PendingSettings.apply(for: game, waitForApplication: true) { fputs($0 + "\n", stderr) } }
        catch { fputs("Saved settings could not be applied: " + error.localizedDescription + "\n", stderr); exit(1) }
    }
}
