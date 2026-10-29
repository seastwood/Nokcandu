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
