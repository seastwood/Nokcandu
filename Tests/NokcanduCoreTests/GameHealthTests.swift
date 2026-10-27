import XCTest
@testable import NokcanduCore

final class GameHealthTests: XCTestCase {
    func testElapsedTime() {
        XCTAssertEqual(StuckGames.seconds("00:45"), 45)
        XCTAssertEqual(StuckGames.seconds("05:18"), 318)
        XCTAssertEqual(StuckGames.seconds("01:02:03"), 3723)
        XCTAssertEqual(StuckGames.seconds("2-00:00:01"), 172801)
    }

    func testMatchingWindowsPrograms() {
        let ps = """
          24149 05:18 D:\\Diablo II Resurrected\\D2R.exe -uid osi
          23954 05:58 C:\\windows\\system32\\explorer.exe /desktop
          32701 00:01 /bin/bash /Users/x/Applications/Diablo II Resurrected.app/Contents/MacOS/game-launcher
          99    00:10 C:/ProgramData/Battle.net/Agent/Agent.9852/Agent.exe --session=1
        """
        let m = StuckGames.matching(ps, programs: ["d2r.exe"])
        XCTAssertEqual(m, [StuckGames.Process(pid: 24149, program: "d2r.exe", seconds: 318)])
        XCTAssertTrue(StuckGames.matching(ps, programs: []).isEmpty)
    }

    func testSavedHotCorners() {
        let s = HotCorners.parse("123\n2 0\n0 0\n1 0\n14 0\n")
        XCTAssertEqual(s?.pid, 123)
        XCTAssertEqual(s?.corners.map { $0.action }, [2, 0, 1, 14])
        XCTAssertNil(HotCorners.parse("garbage"))
    }
}
