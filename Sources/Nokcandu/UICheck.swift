import AppKit
import SwiftUI
import NokcanduCore

/// `Nokcandu --ui-check <report file>`: lays out the main window at its smallest size in every sidebar tab, with
/// worst-case content (many games with very long names, warnings showing, a game selected), and checks that
/// nothing needs more room than the window has. A view that does pushes the whole window's layout past its edges:
/// the sidebar tabs, search field and footer end up off screen (a long login-item warning did this once).
///
/// It runs with an inert model: no services start, no library is read, no setting is saved, and controllers
/// aren't touched, so it can run while Nokcandu itself is open. build-app.sh --test runs it before installing.
enum UICheck {
    static var reportPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-check") else { return nil }
        return i + 1 < args.count ? args[i + 1] : "/dev/stdout"
    }

    /// The window's smallest size (LibraryView's minimum frame in NokcanduApp).
    static let minimum = CGSize(width: 860, height: 680)

    struct Scenario {
        var name: String
        var tab: AppModel.SidebarTab
        var conflicts: Bool
        var selectGame: Bool
        var size: CGSize
    }

    static var scenarios: [Scenario] {
        var out: [Scenario] = []
        for size in [minimum, CGSize(width: 1400, height: 900)] {
            for tab in AppModel.SidebarTab.allCases {
                for conflicts in [false, true] {
                    for select in tab == .games ? [false, true] : [false] {
                        out.append(Scenario(name: "\(tab.rawValue) \(Int(size.width))x\(Int(size.height))" + (conflicts ? " +warning" : "") + (select ? " +game" : ""),
                                            tab: tab, conflicts: conflicts, selectGame: select, size: size))
                    }
                }
            }
        }
        return out
    }

    @MainActor static func runAndExit(_ report: String) -> Never {
        AppModel.inert = true
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let long = "An Extremely Long Game Name That Keeps Going Far Past The Edge Of The Sidebar (Community Edition)"
        let games = (0..<60).map { i in
            InstalledGame.layoutSample(name: i % 3 == 0 ? "\(long) \(i)" : "Game \(i)",
                                       at: URL(fileURLWithPath: "/nonexistent/nokcandu-ui-check/Game \(i).app"))
        }
        let warning = GamesVolumeConflict(label: "com.example.a-very-long-login-item-label-that-keeps-going.mount",
                                          file: URL(fileURLWithPath: "/nonexistent/nokcandu-ui-check/item.plist"),
                                          images: ["/Volumes/Drive/A Very Long Games Volume Name Used To Check Layout.sparsebundle"],
                                          canTurnOff: true)
        var lines: [String] = []
        var failures = 0
        for s in scenarios {
            let model = AppModel()
            model.fillForLayoutCheck(games: games, conflicts: s.conflicts ? [warning, warning] : [])
            model.sidebarTab = s.tab
            if s.selectGame { model.selection = games.first?.id }
            let problems = check(model: model, size: s.size)
            lines.append((problems.isEmpty ? "ok    " : "FAIL  ") + s.name + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; ")))
            failures += problems.isEmpty ? 0 : 1
        }
        lines.append(failures == 0 ? "UI check passed (\(scenarios.count) layouts)." : "UI check FAILED: \(failures) of \(scenarios.count) layouts.")
        let text = lines.joined(separator: "\n") + "\n"
        if report == "/dev/stdout" { print(text, terminator: "") } else { try? text.write(toFile: report, atomically: true, encoding: .utf8) }
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func check(model: AppModel, size: CGSize) -> [String] {
        var problems: [String] = []
        let root = LibraryView().environmentObject(model).frame(minWidth: minimum.width, minHeight: minimum.height)
        // The smallest size the content can be laid out in, at the window's width.
        let needed = NSHostingController(rootView: root).sizeThatFits(in: CGSize(width: size.width, height: 1))
        if needed.height > size.height + 1 { problems.append("needs \(Int(needed.height)) pt of height, the window has \(Int(size.height))") }
        let neededWidth = NSHostingController(rootView: root).sizeThatFits(in: CGSize(width: 1, height: size.height))
        if neededWidth.width > size.width + 1 { problems.append("needs \(Int(neededWidth.width)) pt of width, the window has \(Int(size.width))") }

        // Laid out in a real (never shown) window: the sidebar tabs must sit inside the window, below its title bar.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.setContentSize(size)
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let tabs = find(NSSegmentedControl.self, in: hosting) {
            let r = tabs.convert(tabs.bounds, to: nil)
            let visible = window.contentLayoutRect
            if r.minY < visible.minY - 1 || r.maxY > visible.maxY + 1 {
                problems.append("sidebar tabs are outside the window (at y \(Int(r.minY))–\(Int(r.maxY)), visible \(Int(visible.minY))–\(Int(visible.maxY)))")
            }
        } else if model.features.visible.count > 1 {
            problems.append("sidebar tabs weren't laid out")
        }
        window.close()
        return problems
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }
}
