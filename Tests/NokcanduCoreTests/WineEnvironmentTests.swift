import XCTest
@testable import NokcanduCore

final class WineEnvironmentTests:XCTestCase {
    func testNativeAndShellEnvironmentsFindBundledMediaLibraries() throws {
        let contents=URL(fileURLWithPath:"/tmp/Game's Folder.app/Contents")
        let expected=contents.path+"/Frameworks:"+contents.path+WineEnvironment.mediaSuffix+":/usr/lib"
        XCTAssertEqual(WineTools.environment(contents:contents)["DYLD_FALLBACK_LIBRARY_PATH"],expected)
        for variable in ["CONTENTS","HC"] {
            let command="export "+variable+"="+CustomGames.shellQuote(contents.path)+"\n"+WineEnvironment.exportLine(variable)+"\nprintf '%s' \"$DYLD_FALLBACK_LIBRARY_PATH\""
            let r=try Shell.run("/bin/bash",["-c",command]);XCTAssertTrue(r.ok);XCTAssertEqual(r.stdout,expected)
        }
    }
    func testGeneratedScriptsAndPinnedRecipeNormalization() throws {
        let c=CustomGameConfig(id:"g",name:"Game",source:.folder,exe:#"C:\Games\G\game.exe"#,graphics:.classic3D)
        XCTAssertTrue(CustomGames.launcherScript(for:c).contains(WineEnvironment.mediaSuffix))
        XCTAssertTrue(SharedSteam.helperScript().contains(WineEnvironment.mediaSuffix))
        let link=HostedGameLink(hostApp:"/tmp/EA.app",launcher:.ea,id:"g",name:"Game",exe:#"C:\Game.exe"#)
        XCTAssertTrue(HostedSettings.script(link,settings:.init()).contains(WineEnvironment.mediaSuffix))
        let original="export DYLD_FALLBACK_LIBRARY_PATH=\"$CONTENTS/Frameworks:/usr/lib\"\nexport PATH=/usr/bin:/bin\n# Leave my other edits alone\n"
        let upgraded=try XCTUnwrap(HelperPatch.add(to:original))
        XCTAssertTrue(upgraded.contains(WineEnvironment.mediaSuffix))
        XCTAssertEqual(HelperPatch.strip(upgraded),original)
        XCTAssertNil(HelperPatch.add(to:upgraded))
        XCTAssertTrue(upgraded.contains("# Leave my other edits alone"))
    }
    func testInstallerEnvironmentGetsTheSameMediaPath() {
        let state=InstallState(installID:UUID().uuidString,recipeID:"custom",targetApp:"/tmp/New Game.app")
        let ctx=InstallContext(recipe:CustomInstall.installRecipe(name:"New Game"),state:state,library:[],log:{_ in})
        XCTAssertEqual(ctx.wineEnvironment["DYLD_FALLBACK_LIBRARY_PATH"],WineEnvironment.libraryPath(contents:ctx.contents))
    }
    func testSteamRequiresRestartWhenLibraryEnvironmentChanges() throws {
        let helper=SharedSteam.helperScript()
        let start=try XCTUnwrap(helper.range(of:"config_id() {"))
        let end=try XCTUnwrap(helper.range(of:"\n# --status:",range:start.upperBound..<helper.endIndex))
        let function=String(helper[start.lowerBound..<end.lowerBound])
        func fingerprint(_ libraries:String) throws -> String {
            let command="MODE=dx9\nSTATE=/tmp/nonexistent-nok-media-fixture\nDYLD_FALLBACK_LIBRARY_PATH="+CustomGames.shellQuote(libraries)+"\n"+function+"\nconfig_id"
            let result=try Shell.run("/bin/bash",["-c",command]);XCTAssertTrue(result.ok,result.combined);return result.stdout
        }
        let old=try fingerprint("/tmp/Contents/Frameworks:/usr/lib")
        let new=try fingerprint(WineEnvironment.libraryPath(contents:URL(fileURLWithPath:"/tmp/Contents")))
        XCTAssertNotEqual(old,new,"A running Steam must not silently keep the old media environment")
    }

}
