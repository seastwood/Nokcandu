import XCTest
@testable import NokcanduCore

final class EngineGraphicsTests:XCTestCase {
    /// Minimal PE import table, with no game/runtime bytes.
    func image(_ imports:[String], is64:Bool = false) -> Data {
        var d=Data(repeating:0,count:4096)
        func u16(_ o:Int,_ v:UInt16) { d[o]=UInt8(v & 255);d[o+1]=UInt8(v >> 8) }
        func u32(_ o:Int,_ v:UInt32) { for i in 0..<4 { d[o+i]=UInt8((v >> (8*i)) & 255) } }
        u16(0,0x5a4d);u32(0x3c,0x80);u32(0x80,0x4550);u16(0x86,1);u16(0x94,0xf0)
        let opt=0x98, dd=opt+(is64 ? 112:96), section=opt+0xf0
        u16(opt,is64 ? 0x20b:0x10b);u32(dd-4,16);u32(dd+8,0x1000);u32(dd+12,UInt32((imports.count+1)*20))
        u32(section+8,0x1000);u32(section+12,0x1000);u32(section+16,0x1000);u32(section+20,0x200)
        var nameOffset=0x600
        for (i,name) in imports.enumerated() {
            u32(0x200+i*20+12,UInt32(0x1000+nameOffset-0x200))
            let bytes=Data(name.utf8)+Data([0]);d.replaceSubrange(nameOffset..<nameOffset+bytes.count,with:bytes);nameOffset += bytes.count
        }
        return d
    }
    func testDelayImportAndBootstrapDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("Launcher.exe")
        try image(["KERNEL32.dll"], is64: true).write(to: launcher)
        var delayed = image([], is64: true)
        func u32(_ o: Int, _ v: UInt32) { for i in 0..<4 { delayed[o+i] = UInt8((v >> (8*i)) & 255) } }
        let dd = 0x98 + 112
        u32(dd + 13*8, 0x1100); u32(dd + 13*8 + 4, 64)
        u32(0x300, 1); u32(0x304, 0x1400)
        delayed.replaceSubrange(0x600..<0x60a, with: Data("d3d11.dll\0".utf8))
        try delayed.write(to: root.appendingPathComponent("Game.exe"))
        XCTAssertTrue(try XCTUnwrap(PEFile.inspect(root.appendingPathComponent("Game.exe"))).imports.contains("d3d11.dll"))
        XCTAssertEqual(GraphicsPreset.suggest(for: PEFile.inspectForGraphics(launcher)), .modern3D)
        let evidence = try XCTUnwrap(Recommendations.evidence(program: launcher))
        XCTAssertTrue(Recommendations.recommend(evidence, graphics: .classic3D, confirmedGraphics: nil, installed: []).contains { $0.action == .graphics(.modern3D) })
        XCTAssertFalse(Recommendations.recommend(evidence, graphics: .classic3D, confirmedGraphics: .classic3D, installed: []).contains { if case .graphics = $0.action { return true }; return false })
        // Conflicting sibling evidence is not enough to select a renderer.
        try image(["d3d9.dll"], is64: true).write(to: root.appendingPathComponent("Other.exe"))
        XCTAssertEqual(PEFile.inspectForGraphics(launcher)?.imports, ["KERNEL32.dll"])
        // Ordinary programs never inherit unrelated sibling graphics.
        let ordinary = root.appendingPathComponent("Ordinary.exe")
        try image(["KERNEL32.dll"], is64: true).write(to: ordinary)
        XCTAssertEqual(PEFile.inspectForGraphics(ordinary)?.imports, ["KERNEL32.dll"])
    }

    func testInstalledRocketLeagueDetectionWhenAvailable() throws {
        let exe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Sikarugir/Rocket League®.app/Contents/SharedSupport/prefix/drive_c/Games/Rocket League®/Binaries/Win64/Launcher.exe")
        guard FileManager.default.fileExists(atPath: exe.path) else { throw XCTSkip("Rocket League not installed") }
        let original = try XCTUnwrap(PEFile.inspectWithLoadedDLLs(exe))
        XCTAssertFalse(original.imports.contains("d3d11.dll"))
        let detected = try XCTUnwrap(PEFile.inspectForGraphics(exe))
        XCTAssertTrue(detected.imports.contains("d3d11.dll"))
        XCTAssertEqual(GraphicsPreset.suggest(for: detected), .modern3D)
    }

    func testImportedEngineGraphicsCyclesAndDirectExecutablePrecedence() throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
        let exe=root.appendingPathComponent("Game.exe")
        try image(["KERNEL32.dll","Engine.dll"]).write(to:exe)
        try image(["Child.dll","Game.exe"]).write(to:root.appendingPathComponent("engine.DLL"))
        try image(["OPENGL32.dll","Engine.dll"]).write(to:root.appendingPathComponent("Child.dll"))
        try image(["d3d12.dll"]).write(to:root.appendingPathComponent("Unrelated.dll"))
        let probe=try XCTUnwrap(PEFile.inspectWithLoadedDLLs(exe))
        XCTAssertEqual(GraphicsPreset.suggest(for:probe),.compatible)
        XCTAssertFalse(probe.imports.contains("d3d12.dll"))
        let evidence=try XCTUnwrap(Recommendations.evidence(program:exe))
        let recommendations=Recommendations.recommend(evidence,graphics:.classic3D,confirmedGraphics:nil,installed:[])
        XCTAssertTrue(recommendations.contains { $0.action == .graphics(.compatible) })
        XCTAssertTrue(recommendations.first?.reason.contains("Child.dll") == true)
        XCTAssertFalse(Recommendations.recommend(evidence,graphics:.classic3D,confirmedGraphics:.classic3D,installed:[]).contains { if case .graphics = $0.action { return true }; return false })
        try image(["d3d9.dll","Engine.dll"]).write(to:exe)
        XCTAssertEqual(GraphicsPreset.suggest(for:PEFile.inspectWithLoadedDLLs(exe)),.classic3D)
    }
    func testRejectsExternalEngineSymlinkAndWrongArchitecture() throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
        let external=root.appendingPathComponent("outside"), exe=root.appendingPathComponent("Game.exe"), engine=root.appendingPathComponent("Engine.dll")
        try fm.createDirectory(at:external,withIntermediateDirectories:true)
        let other=external.appendingPathComponent("Engine.dll")
        try image(["Engine.dll"]).write(to:exe);try image(["opengl32.dll"]).write(to:other)
        try fm.createSymbolicLink(at:engine,withDestinationURL:other)
        XCTAssertEqual(GraphicsPreset.suggest(for:PEFile.inspectWithLoadedDLLs(exe)),.compatible)
        try fm.removeItem(at:engine);try image(["opengl32.dll"],is64:true).write(to:engine)
        XCTAssertEqual(GraphicsPreset.suggest(for:PEFile.inspectWithLoadedDLLs(exe)),.compatible)
    }
}
