import XCTest
@testable import NokcanduCore

final class RunStateTests: XCTestCase {
    func testWindowsProgramTail() {
        XCTAssertEqual(GameLauncher.windowsProgramTail(#"C:\Program Files (x86)\StarCraft\x86_64\StarCraft.exe"#), #"x86_64\starcraft.exe"#)
        XCTAssertEqual(GameLauncher.windowsProgramTail("C:/Games/Worms/WA.exe"), #"worms\wa.exe"#)
        XCTAssertEqual(GameLauncher.windowsProgramTail("game.exe"), #"\game.exe"#)
        XCTAssertNil(GameLauncher.windowsProgramTail(#"C:\Games\readme.txt"#))
        XCTAssertNil(GameLauncher.windowsProgramTail(nil))
    }

    func testProcessSnapshotSeesThisProcess() {
        XCTAssertTrue(GameLauncher.processSnapshot().contains { $0.0 == getpid() })
    }
}

final class WineOwnershipTests: XCTestCase {
    func testLoadersNamedAfterTheirApp() {
        let c = URL(fileURLWithPath: "/Apps/Battle.net.app/Contents")
        XCTAssertTrue(WineTools.owns(executable: "/Apps/Battle.net.app/Contents/SharedSupport/GameApp/StarCraft.app/Contents/MacOS/StarCraft", contents: c))
        XCTAssertTrue(WineTools.owns(executable: "/Apps/Battle.net.app/Contents/SharedSupport/GameApp/Battle.net.app/Contents/MacOS/wine", contents: c))
        XCTAssertTrue(WineTools.owns(executable: "/Apps/Battle.net.app/Contents/SharedSupport/wine/bin/wineserver", contents: c))
        XCTAssertFalse(WineTools.owns(executable: "/Apps/Other.app/Contents/SharedSupport/GameApp/X.app/Contents/MacOS/X", contents: c))
        XCTAssertFalse(WineTools.owns(executable: "/Apps/Battle.net.app/Contents/SharedSupport/GameApp/X.app/Contents/Resources/x", contents: c))
    }
}
