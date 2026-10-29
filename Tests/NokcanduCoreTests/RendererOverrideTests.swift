import XCTest
@testable import NokcanduCore

final class RendererOverrideTests: XCTestCase {
    func testShaderFixPreservesEveryRendererAndExplicitDllRulesWin() throws {
        for mode in GraphicsPreset.allCases {
            let defaults = CompatibilityFixes.overrides(mode.dllOverrides)
            let merged = mode.mergedDLLOverrides("d3dcompiler_47=n,b;dsound=n;d3d9=n")
            let rules = CompatibilityFixes.overrides(merged)
            for (dll, order) in defaults where dll != "d3d9" { XCTAssertEqual(rules[dll], order, mode.rawValue) }
            XCTAssertEqual(rules["d3d9"], "n")
            XCTAssertEqual(rules["dsound"], "n")
            XCTAssertEqual(rules["d3dcompiler_47"], "n,b")
            // Execute only the generated export lines: inspect actual shell values, not just text.
            var config = CustomGameConfig(id:"test",name:"Test",source:.folder,exe:#"C:\Games\Test\Test.exe"#,graphics:mode)
            config.environment = ["WINEDLLOVERRIDES":"d3dcompiler_47=n,b;dsound=n;d3d9=n"]
            let lines = CustomGames.launcherScript(for:config).split(separator:"\n").filter { $0.hasPrefix("export WINEDLLOVERRIDES=") }
            let script = lines.joined(separator:"\n") + "\nprintf '%s' \"$WINEDLLOVERRIDES\""
            let r = try Shell.run("/bin/bash", ["-c",script])
            XCTAssertTrue(r.ok)
            XCTAssertEqual(CompatibilityFixes.overrides(r.stdout),rules)
        }
    }
    func testHostedGameUsesOneMergedMap() throws {
        let link = HostedGameLink(hostApp:"/nonexistent/EA.app",launcher:.ea,id:"test",name:"Test",exe:#"C:\Games\Test\Test.exe"#)
        var settings=HostedSettings.Settings();settings.graphics = .dxmt
        settings.environment=["WINEDLLOVERRIDES":"d3dcompiler_47=n,b;d3d11=n"]
        let exports=HostedSettings.script(link,settings:settings).split(separator:"\n").filter { $0.hasPrefix("export WINEDLLOVERRIDES=") }
        let r=try Shell.run("/bin/bash",["-c",exports.joined(separator:"\n") + "\nprintf '%s' \"$WINEDLLOVERRIDES\""])
        XCTAssertTrue(r.ok)
        let rules=CompatibilityFixes.overrides(r.stdout)
        XCTAssertEqual(rules["dxgi"],"b");XCTAssertEqual(rules["d3d11"],"n");XCTAssertEqual(rules["d3dcompiler_47"],"n,b")
    }
}
