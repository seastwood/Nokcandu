import XCTest
@testable import NokcanduCore

final class VulkanLayerTests: XCTestCase {
    private func config(_ layer: String?, graphics: GraphicsPreset = .classic3D) -> CustomGameConfig {
        var c = CustomGameConfig(id: "bf2", name: "BF2", source: .folder, exe: #"C:\Games\BF2\BF2.exe"#, graphics: graphics)
        c.vulkanLayer = layer; return c
    }
    func testMoltenVKIsOnlyUsedWhenChosenForOlder3DGames() {
        let kosmic = CustomGames.launcherScript(for: config(nil))
        XCTAssertFalse(kosmic.contains("MoltenVK_icd.json"))
        XCTAssertTrue(kosmic.contains("kosmickrisp_mesa_icd.json"))
        XCTAssertFalse(kosmic.contains("maxFrameLatency"), "frame latency is DXVK's own unless Low latency is chosen")
        let molten = CustomGames.launcherScript(for: config("moltenvk"))
        XCTAssertTrue(molten.contains(#"VK_DRIVER_FILES="$CONTENTS/Resources/vulkan/icd.d/MoltenVK_icd.json""#))
        XCTAssertTrue(molten.contains(#"WINEDLLPATH_D9VK="$SUPPORT/renderer/dxvk/wine""#))
        XCTAssertTrue(molten.contains(#"[ -f "$SUPPORT/renderer/dxvk/wine/i386-windows/d3d9.dll" ]"#), "falls back to the default when the files aren't there")
        // The choice is set after perf.env so it wins over the default renderer lines.
        let perf = molten.range(of: "perf.env")!.lowerBound, choice = molten.range(of: "MoltenVK_icd.json")!.lowerBound
        XCTAssertLessThan(perf, choice)
        XCTAssertFalse(CustomGames.launcherScript(for: config("moltenvk", graphics: .modern3D)).contains("MoltenVK_icd.json"), "only for Older 3D games")
    }
    func testOlderSavedGamesDecodeWithoutALayer() throws {
        let c = config(nil)
        let back = try JSONDecoder().decode(CustomGameConfig.self, from: JSONEncoder().encode(c))
        XCTAssertNil(back.vulkanLayer); XCTAssertFalse(back.usesMoltenVK)
    }
}
