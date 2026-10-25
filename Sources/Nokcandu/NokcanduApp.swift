import SwiftUI
import AppKit
import NokcanduCore

@main
struct NokcanduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Nokcandu") {
            LibraryView()
                .environmentObject(model)
                .onOpenURL { url in model.openURL(url) }
                .frame(minWidth: 860, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Install a Game…") { model.showInstaller = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Steam Library…") { model.showSteamLibrary = true }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r")
                Button("Updates…") { model.showUpdates = true }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Setup Checklist…") { model.showWelcome = true }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain SwiftPM executable: make sure it behaves like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Games") {
                    ForEach(model.games) { g in
                        GameRow(game: g, state: model.runStates[g.id] ?? .notRunning).tag(g.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .overlay {
                if model.games.isEmpty {
                    ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                                           description: Text("Install a game or set up Steam with the buttons below. Game apps live in \(NokPaths.gameAppsFolder.path.replacingOccurrences(of: NokPaths.home.path, with: "~"))."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.showSteamLibrary = true } label: {
                        Label("Steam Library…", systemImage: "cloud")
                    }
                    Button { model.showInstaller = true } label: {
                        Label("Install a Game…", systemImage: "plus.circle")
                    }
                    Button { model.showStorage = true } label: {
                        Label("Storage…", systemImage: "internaldrive")
                    }
                    Button { model.showUpdates = true } label: {
                        Label(model.updateCount > 0 ? "Updates (\(model.updateCount))…" : "Updates…",
                              systemImage: model.updateCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderless)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let g = model.selectedGame {
                GameDetailView(game: g).id(g.id)
            } else {
                ContentUnavailableView("Choose a game", systemImage: "gamecontroller")
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $model.showInstaller, onDismiss: { model.installerStartsSteamHost = false }) {
            InstallerView().environmentObject(model)
        }
        .sheet(isPresented: $model.showWelcome) {
            WelcomeView().environmentObject(model)
        }
        .sheet(isPresented: $model.showStorage) {
            StorageView().environmentObject(model)
        }
        .sheet(isPresented: $model.showUpdates) {
            UpdatesView().environmentObject(model)
        }
        .sheet(isPresented: $model.showSteamLibrary) {
            SteamLibraryView().environmentObject(model)
        }
        .overlay(alignment: .bottom) {
            if let b = model.banner {
                BannerView(banner: b) { model.banner = nil }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}

struct GameRow: View {
    let game: InstalledGame
    let state: RunState

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: game.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var subtitle: String {
        if case .launcherRunning = state { return "Running" }
        if game.isSteamHost { return "Shared Steam" }
        if game.usesSharedSteam { return "Steam game" }
        return game.isManaged ? "Ready" : "Not set up by Nokcandu"
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
        .task(id: banner.id) {
            try? await Task.sleep(nanoseconds: banner.isError ? 12_000_000_000 : 5_000_000_000)
            dismiss()
        }
    }
}
