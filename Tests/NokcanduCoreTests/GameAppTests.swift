import XCTest
@testable import NokcanduCore

final class GameAppTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        GameApp.useSystemTools = false
        GameApp.enabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gameapp-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("Host.app/Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent().appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho wine\n".utf8).write(to: bin.appendingPathComponent("wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("wine").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        GameApp.useSystemTools = true
        GameApp.enabled = true
    }

    var host: URL { root.appendingPathComponent("Host.app/Contents") }
    var dir: URL { host.appendingPathComponent("SharedSupport/GameApp") }

    func testWrappersProgramsAndCategories() throws {
        GameApp.ensure(host: host, wrappers: [.init(name: "Steam", iconFrom: nil, isGame: false),
                                             .init(name: "Counter-Strike: Source", iconFrom: nil)],
                       programs: ["steam.exe": "Steam", "cstrike.exe": "Counter-Strike: Source", "other.exe": "Not Wrapped"],
                       fallback: "Steam")
        let list = try String(contentsOf: dir.appendingPathComponent("programs.tsv"), encoding: .utf8)
        XCTAssertTrue(list.hasPrefix("#engine\t"))
        XCTAssertTrue(list.contains("*\tSteam.app\n"))
        XCTAssertTrue(list.contains("cstrike.exe\tCounter-Strike- Source.app\n"))
        XCTAssertFalse(list.contains("other.exe"))
        let game = NSDictionary(contentsOf: dir.appendingPathComponent("Counter-Strike- Source.app/Contents/Info.plist"))!
        XCTAssertEqual(game["CFBundleName"] as? String, "Counter-Strike: Source")
        XCTAssertEqual(game["LSApplicationCategoryType"] as? String, "public.app-category.games")
        XCTAssertEqual(game["GCSupportsGameMode"] as? Bool, true)
        XCTAssertEqual(game["LSUIElement"] as? Bool, true)
        let steam = NSDictionary(contentsOf: dir.appendingPathComponent("Steam.app/Contents/Info.plist"))!
        XCTAssertNil(steam["GCSupportsGameMode"])
        XCTAssertEqual(steam["LSApplicationCategoryType"] as? String, "public.app-category.utilities")
        let c = dir.appendingPathComponent("Steam.app/Contents")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: c.appendingPathComponent("MacOS/wine").path))
        // Named after the program so macOS's privacy lists show "Steam", not "wine".
        XCTAssertEqual(steam["CFBundleExecutable"] as? String, "Steam")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: c.appendingPathComponent("MacOS/Steam").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: c.appendingPathComponent("MacOS/wine").path), "Steam")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: c.appendingPathComponent("lib").path), "../../../wine/lib")
        // The links resolve to the engine.
        XCTAssertEqual(c.appendingPathComponent("lib").resolvingSymlinksInPath().path,
                       host.appendingPathComponent("SharedSupport/wine/lib").resolvingSymlinksInPath().path)
    }

    func testOldWrapperWithLoaderAtWineIsMigrated() throws {
        GameApp.ensure(host: host, wrappers: [.init(name: "G", iconFrom: nil)], programs: [:], fallback: "G")
        let m = dir.appendingPathComponent("G.app/Contents/MacOS")
        // Make it look like a wrapper from before: the loader itself at MacOS/wine.
        try FileManager.default.removeItem(at: m.appendingPathComponent("wine"))
        try FileManager.default.moveItem(at: m.appendingPathComponent("G"), to: m.appendingPathComponent("wine"))
        GameApp.ensure(host: host, wrappers: [.init(name: "G", iconFrom: nil)], programs: [:], fallback: "G")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: m.appendingPathComponent("wine").path), "G")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: m.appendingPathComponent("G").path))
    }

    func testStaleWrappersRemovedAndSwitchOff() throws {
        GameApp.ensure(host: host, wrappers: [.init(name: "Old Name", iconFrom: nil)], programs: [:], fallback: "Old Name")
        GameApp.ensure(host: host, wrappers: [.init(name: "New Name", iconFrom: nil)], programs: [:], fallback: "New Name")
        let apps = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".app") }
        XCTAssertEqual(apps, ["New Name.app"])
        GameApp.enabled = false
        GameApp.ensure(host: host, wrappers: [.init(name: "New Name", iconFrom: nil)], programs: [:], fallback: "New Name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testEngineUpdateRefreshesLoader() throws {
        GameApp.ensure(host: host, wrappers: [.init(name: "G", iconFrom: nil)], programs: [:], fallback: "G")
        let wine = host.appendingPathComponent("SharedSupport/wine/bin/wine")
        try Data("#!/bin/sh\necho new engine\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: wine.path)
        GameApp.ensure(host: host, wrappers: [.init(name: "G", iconFrom: nil)], programs: [:], fallback: "G")
        let copy = try String(contentsOf: dir.appendingPathComponent("G.app/Contents/MacOS/wine"), encoding: .utf8)
        XCTAssertTrue(copy.contains("new engine"))
        let list = try String(contentsOf: dir.appendingPathComponent("programs.tsv"), encoding: .utf8)
        XCTAssertTrue(list.hasPrefix("#engine\t\(GameApp.engineStamp(wine)!)\n"))
    }

    func testHelperPatchKeepsLauncherRecognised() throws {
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/generals-launcher")
        let text = try String(contentsOf: template, encoding: .utf8)
        let patched = try XCTUnwrap(HelperPatch.add(to: text))
        XCTAssertNil(HelperPatch.add(to: patched))
        XCTAssertEqual(HelperPatch.strip(patched), text)
        let lines = patched.components(separatedBy: "\n")
        let path = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("export PATH=") })
        XCTAssertTrue(lines[path + 1].hasPrefix(HelperPatch.marker))
        XCTAssertNotNil(RecipeCatalog.zeroHour.knownLauncherHashes[Hashing.sha256(data: Data(HelperPatch.strip(patched).utf8))])
        // Valid bash.
        let f = root.appendingPathComponent("launcher"); try Data(patched.utf8).write(to: f)
        XCTAssertEqual(try Shell.run("/bin/bash", ["-n", f.path]).status, 0)
    }
}

extension GameAppTests {
    func testRepairDetectsCorruptSignedLoaderEvenWhenSourceStampMatches() throws {
        let wrappers: [GameApp.Wrapper] = [.init(name: "G", iconFrom: nil)]
        GameApp.ensure(host: host, wrappers: wrappers, programs: [:], fallback: "G")
        let executable = dir.appendingPathComponent("G.app/Contents/MacOS/G")
        let expected = try Data(contentsOf: executable)
        try Data("corrupt loader".utf8).write(to: executable)
        GameApp.ensure(host: host, wrappers: wrappers, programs: [:], fallback: "G")
        XCTAssertEqual(try Data(contentsOf: executable), expected)
        try FileManager.default.removeItem(at: executable)
        GameApp.ensure(host: host, wrappers: wrappers, programs: [:], fallback: "G")
        XCTAssertEqual(try Data(contentsOf: executable), expected)
    }
}

extension GameAppTests {
    func testRealSignedWrapperStaysValidAfterChecksumAndCorruptionRecovery() throws {
        let wine = host.appendingPathComponent("SharedSupport/wine/bin/wine")
        try FileManager.default.removeItem(at: wine)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: wine)
        try FileManager.default.copyItem(at: wine, to: wine.deletingLastPathComponent().appendingPathComponent("wineserver"))
        try NokPaths.ensure(host.appendingPathComponent("SharedSupport/wine/share"))
        GameApp.useSystemTools = true
        let name = "Nokcandu Integrity Fixture " + UUID().uuidString.prefix(8)
        let app = dir.appendingPathComponent(name + ".app")
        defer { GameApp.remove(app); GameApp.useSystemTools = false }
        let wrappers: [GameApp.Wrapper] = [.init(name: name, iconFrom: nil)]
        GameApp.ensure(host: host, wrappers: wrappers, programs: [:], fallback: name)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wine.path))
        XCTAssertTrue(GameApp.enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "Wrappers: \(String(describing: try? FileManager.default.contentsOfDirectory(atPath: dir.path)))")
        var checked = try Shell.run("/usr/bin/codesign", ["--verify", app.path], timeout: 30)
        XCTAssertTrue(checked.ok, checked.combined)
        let loader = app.appendingPathComponent("Contents/MacOS/" + name)
        try Data("corrupted loader".utf8).write(to: loader)
        GameApp.ensure(host: host, wrappers: wrappers, programs: [:], fallback: name)
        checked = try Shell.run("/usr/bin/codesign", ["--verify", app.path], timeout: 30)
        XCTAssertTrue(checked.ok, checked.combined)
        XCTAssertEqual(try Hashing.sha256(file: loader), try String(contentsOf: dir.appendingPathComponent("." + name + ".loader-sha256"), encoding: .utf8))
    }
}
