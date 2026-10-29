import XCTest
@testable import NokcanduCore

final class RecommendationTests: XCTestCase {
    func ev(_ program: [String], dlls: [String: [String]] = [:], shipped: [String] = [], is64: Bool = false) -> Recommendations.Evidence {
        var by: [String: String] = [:]
        for i in program { by[i] = "Game.exe" }
        for (d, imps) in dlls { for i in imps where by[i] == nil { by[i] = d } }
        return .init(program: "Game.exe", is64Bit: is64, importedBy: by, shipped: Set(shipped), programImports: Set(program))
    }
    func ids(_ r: [Recommendation]) -> [String] { r.map(\.id) }

    func testDirectX8GameGetsOlder3DAndD3D8to9() {
        let r = Recommendations.recommend(ev(["d3d8.dll", "dinput8.dll"]), graphics: .modern3D, confirmedGraphics: nil, installed: [])
        XCTAssertEqual(ids(r), ["graphics-dx9", "fix-d3d8to9"])
        XCTAssertTrue(r[0].reason.contains("d3d8.dll"))
        // Already in the right mode with the fix: nothing to do.
        XCTAssertTrue(Recommendations.recommend(ev(["d3d8.dll"]), graphics: .classic3D, confirmedGraphics: nil, installed: [.d3d8to9]).isEmpty)
    }

    func testConfirmedModeIsRespected() {
        let r = Recommendations.recommend(ev(["d3d8.dll"]), graphics: .compatible, confirmedGraphics: .compatible, installed: [])
        XCTAssertTrue(r.isEmpty)
    }

    func testShaderLibrariesFromGameDLLs() {
        let e = ev(["d3d9.dll"], dlls: ["Engine.dll": ["d3dx9_43.dll", "d3dcompiler_47.dll"]])
        let r = Recommendations.recommend(e, graphics: .classic3D, confirmedGraphics: nil, installed: [])
        XCTAssertEqual(ids(r), ["fix-directx9-extras", "fix-shader-compiler-47"])
        XCTAssertTrue(r[0].reason.hasPrefix("Engine.dll"))
        // Shipped with the game: not needed.
        let shipped = ev(["d3d9.dll"], dlls: ["Engine.dll": ["d3dx9_43.dll", "d3dcompiler_47.dll"]], shipped: ["d3dx9_43.dll", "d3dcompiler_47.dll"])
        XCTAssertTrue(Recommendations.recommend(shipped, graphics: .classic3D, confirmedGraphics: nil, installed: []).isEmpty)
    }

    func testModernAndDirectDrawModes() {
        XCTAssertEqual(ids(Recommendations.recommend(ev(["d3d12.dll", "dxgi.dll"], is64: true), graphics: .modern3D, confirmedGraphics: nil, installed: [])), ["graphics-d3dmetal"])
        XCTAssertEqual(ids(Recommendations.recommend(ev(["d3d11.dll"], is64: true), graphics: .classic3D, confirmedGraphics: nil, installed: [])), ["graphics-dx11"])
        XCTAssertTrue(Recommendations.recommend(ev(["d3d11.dll"], is64: true), graphics: .dxmt, confirmedGraphics: nil, installed: []).isEmpty)
        XCTAssertEqual(ids(Recommendations.recommend(ev(["ddraw.dll"]), graphics: .modern3D, confirmedGraphics: nil, installed: [])), ["graphics-ddraw"])
    }

    func testCinematic() {
        let r = Recommendations.recommend(ev(["d3d9.dll", "quartz.dll"]), graphics: .classic3D, confirmedGraphics: nil, installed: [], usesDirectShow: true)
        XCTAssertEqual(ids(r), ["cinematic"])
    }

    func testStoreProgressLines() {
        let l = StoreTools.Progress.parse("[DLManager] INFO: = Progress: 42.17% (1234/2900), Running for 00:01:10, ETA: 00:03:10")
        XCTAssertEqual(l?.fraction ?? 0, 0.4217, accuracy: 0.0001)
        XCTAssertEqual(l?.label, "42% · about 3 min left")
        let g = StoreTools.Progress.parse("[PROGRESS] INFO: = Progress: 7.50 120/1600, Running for: 00:00:12, ETA: 01:02:00")
        XCTAssertEqual(g?.label, "7% · about 1 h 2 min left")
        XCTAssertNil(StoreTools.Progress.parse("[cli] INFO: Install size: 6.53 GiB"))
        XCTAssertEqual(StoreJobs.key(.epic, "Jaguar"), "epic-Jaguar")
    }
}

final class ProblemReportTests: XCTestCase {
    func testRedaction() {
        let raw = """
        App: /Users/jdoe/Applications/Sikarugir/Game.app
        Owner John Doe on John's MacBook, contact john.doe@example.com
        steamid 76561198012345678
        C:\\users\\jdoe\\AppData and drive_c/users/jdoe/Documents, drive_c/users/Public
        """
        let r = ProblemReport.redact(raw, home: "/Users/jdoe", user: "jdoe", fullName: "John Doe", host: "John's MacBook")
        XCTAssertFalse(r.contains("jdoe")); XCTAssertFalse(r.contains("John")); XCTAssertFalse(r.contains("example.com"))
        XCTAssertTrue(r.contains("~/Applications/Sikarugir/Game.app"))
        XCTAssertTrue(r.contains("<steam id>"))
        XCTAssertTrue(r.contains("drive_c/users/Public"))
        let link = ProblemReport.issueLink(title: "T", body: String(repeating: "x", count: 9000))
        XCTAssertLessThan(link.absoluteString.count, 7000)
    }
}

final class StoreUpdateTests: XCTestCase {
    func testLegendaryUpdateLines() {
        let t = """
        Installed games:
         * Subnautica (App name: Jaguar | Version: 1.0-Mac | Platform: Mac | 6.53 GiB)
          -> Update available! Installed: 1.0-Mac, Latest: 1.1-Mac
         * The Battle of Polytopia (App name: 3ce8 | Version: 2.17 | Platform: Mac | 0.37 GiB)
        """
        let u = StoreUpdates.parseLegendary(t)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u["Jaguar"]?.installed, "1.0-Mac")
        XCTAssertEqual(u["Jaguar"]?.latest, "1.1-Mac")
    }
}

final class CloudSaveTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(CloudSaves.parse("[cli] INFO: Save game for \"X\" is up to date, skipping..."), .upToDate)
        XCTAssertEqual(CloudSaves.parse("[cli] INFO: Cloud save for \"X\" is newer:\n[cli] INFO: Downloading \"X\" save..."), .downloaded)
        XCTAssertEqual(CloudSaves.parse("[cli] INFO: Uploading save..."), .uploaded)
        XCTAssertEqual(CloudSaves.parse("[cli] INFO: No cloud or local savegame found."), .none)
    }
}

final class BottleTests: XCTestCase {
    func testGameFolder() {
        let b = URL(fileURLWithPath: "/tmp/Bottles/Games")
        func f(_ p: String) -> String? { Bottles.gameFolder(for: b.appendingPathComponent("drive_c/" + p), in: b)?.lastPathComponent }
        XCTAssertEqual(f("Program Files (x86)/Foo Game/bin/foo.exe"), "Foo Game")
        XCTAssertEqual(f("GOG Games/Bar/bar.exe"), "Bar")
        XCTAssertEqual(f("Baz/baz.exe"), "Baz")
        XCTAssertNil(f("Program Files (x86)/Steam/steamapps/common/x.exe"))
        XCTAssertNil(f("setup.exe"))
    }
}
