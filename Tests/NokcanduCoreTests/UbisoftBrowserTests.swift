import XCTest
@testable import NokcanduCore

final class UbisoftBrowserTests: XCTestCase {
    func testUnknownBrowserIsNeverChangedAndFixIsHiddenForOtherGames() throws {
        let data=Data(repeating:0,count:UbisoftBrowser.offset+32)
        var looksSimilar=data
        looksSimilar.replaceSubrange(UbisoftBrowser.offset..<UbisoftBrowser.offset+12,with:UbisoftBrowser.before)
        XCTAssertThrowsError(try UbisoftBrowser.patched(data))
        XCTAssertThrowsError(try UbisoftBrowser.patched(looksSimilar))
        let g=try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at:g.appURL) }
        XCTAssertFalse(CompatibilityFixes.visible(.ubisoftBrowser,for:g))
        XCTAssertNotNil(CompatibilityFixes.unavailable(.ubisoftBrowser,for:g))
        XCTAssertFalse(CustomGames.launcherScript(for:g.custom!).contains("UBI_BROWSER="))
    }
    func testArgumentsAndShellAreSafeAndUndoKeepsLaterArguments() throws {
        let previous = #"--language "en US""#
        let applied=UbisoftBrowser.arguments(previous)
        XCTAssertEqual(UbisoftBrowser.arguments(applied),applied)
        XCTAssertEqual(UbisoftBrowser.undoArguments(applied,previous:previous,applied:applied),previous)
        XCTAssertEqual(UbisoftBrowser.undoArguments(applied+" --extra",previous:previous,applied:applied),previous+"  --extra")
        XCTAssertEqual(UbisoftBrowser.undoArguments("--in-process-gpu --extra",previous:"--in-process-gpu",applied:"--in-process-gpu"),"--in-process-gpu --extra")
        let c=CustomGameConfig(id:"ubi",name:"Ubisoft",source:.installer,exe:PCLauncher.ubisoft.defaultExe,graphics:.dxmt)
        let script=CustomGames.launcherScript(for:c)
        XCTAssertTrue(script.contains("fix-ubisoft-browser.json"))
        XCTAssertTrue(script.contains(UbisoftBrowser.originalSHA))
        XCTAssertTrue(script.contains(UbisoftBrowser.patchedSHA))
        XCTAssertFalse(script.contains("--no-sandbox"))
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sh")
        defer { try? FileManager.default.removeItem(at:file) }
        try Data(script.utf8).write(to:file)
        XCTAssertTrue(try Shell.run("/bin/bash",["-n",file.path]).ok)
    }
    func testFreshUbisoftSetupChoosesVerifiedBackendAndChecksClient() async throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        var state=InstallState(installID:UUID().uuidString,recipeID:"custom",targetApp:root.appendingPathComponent("Ubisoft.app").path)
        state.inputs=["name":"Ubisoft Connect","source":"installer","launcherKind":"ubisoft","installerPath":root.appendingPathComponent("setup.exe").path,"acquire.opened":"1"]
        let ctx=InstallContext(recipe:CustomInstall.installRecipe(name:"Ubisoft Connect"),state:state,library:[],log:{_ in})
        defer { try? fm.removeItem(at:ctx.workDir) }
        let program=ctx.prefix.appendingPathComponent("drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/upc.exe")
        try NokPaths.ensure(program.deletingLastPathComponent())
        try OpenUASettingsTests().pe().write(to:program)
        try await CustomInstall.Acquire(source:.installer).run(ctx)
        XCTAssertEqual(ctx.input("exe"),PCLauncher.ubisoft.defaultExe)
        try await CustomInstall.Graphics().run(ctx)
        XCTAssertEqual(ctx.input("graphics"),GraphicsPreset.dxmt.rawValue)
        XCTAssertFalse(CustomInstall.Build().isDone(ctx))
    }
    /// Real official bytes are local licensed installation data, never committed to the repo.
    func testVerifiedOfficialBrowserInstallRepairAndUndo() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_UBISOFT_E2E"]=="1",
              let sourcePath=ProcessInfo.processInfo.environment["NOKCANDU_UBISOFT_BROWSER"] else {
            throw XCTSkip("Set NOKCANDU_UBISOFT_BROWSER to an original official libcef.dll and NOKCANDU_UBISOFT_E2E=1")
        }
        var g=try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at:g.appURL) }
        var c=g.custom!;c.exe = #"C:\Games\T\upc.exe"#;c.graphics = .dxmt;c.arguments="--language en"
        try CustomGames.save(c,to:g);g=CompatibilityFixes.fresh(g)
        let exe=try XCTUnwrap(CompatibilityFixes.program(g));try NokPaths.ensure(exe.deletingLastPathComponent());try OpenUASettingsTests().pe().write(to:exe)
        let file=exe.deletingLastPathComponent().appendingPathComponent("libcef.dll")
        let source=URL(fileURLWithPath:sourcePath)
        let original=try Data(contentsOf:source);XCTAssertEqual(Hashing.sha256(data:original),UbisoftBrowser.originalSHA)
        try original.write(to:file)
        try await CompatibilityFixes.install(.ubisoftBrowser,for:g,log:{_ in})
        g=CompatibilityFixes.fresh(g)
        XCTAssertEqual(try Hashing.sha256(file:file),UbisoftBrowser.patchedSHA)
        XCTAssertEqual(g.custom?.arguments,"--language en --in-process-gpu")
        XCTAssertTrue(Profiles.make(from:g,rating:.playable,notes:nil,install:nil).fixes?.contains("ubisoft-browser")==true)
        // Simulate a launcher update restoring this exact official build. Its normal shell
        // repairs it, and the existing journal can still restore the original afterward.
        try original.write(to:file)
        let block="GAME_DIR="+CustomGames.shellQuote(file.deletingLastPathComponent().path)+"\nSUPPORT="+CustomGames.shellQuote(g.support.path)+"\nCHECK_ONLY=0\nLOCK="+CustomGames.shellQuote(g.logs.appendingPathComponent("test.lock").path)+"\n"+UbisoftBrowser.launcherBlock(g.custom!)
        let repaired=try Shell.run("/bin/bash",["-c",block],timeout:60)
        XCTAssertTrue(repaired.ok,repaired.combined)
        XCTAssertEqual(try Hashing.sha256(file:file),UbisoftBrowser.patchedSHA)
        var unknown=try Data(contentsOf:file);unknown[100] ^= 1
        try unknown.write(to:file)
        let rejected=try Shell.run("/bin/bash",["-c",block],timeout:60)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(try Hashing.sha256(file:file),Hashing.sha256(data:unknown))
        XCTAssertThrowsError(try CompatibilityFixes.undo(.ubisoftBrowser,for:g,log:{_ in}))
        try UbisoftBrowser.patched(original).write(to:file)
        try CompatibilityFixes.undo(.ubisoftBrowser,for:g,log:{_ in})
        XCTAssertEqual(try Hashing.sha256(file:file),UbisoftBrowser.originalSHA)
        XCTAssertEqual(CompatibilityFixes.fresh(g).custom?.arguments,"--language en")
    }
}
