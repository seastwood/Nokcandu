import XCTest
@testable import NokcanduCore

final class PadSocketLeftoverTests: XCTestCase {
    func testOnlyDeadHelpersOwnFilesAreChosen() {
        let names = ["nokcandu-pad-501-100.sock", "nokcandu-pad-501-100.sock.buttons", "nokcandu-pad-501-200.sock",
                     "nokcandu-pad-502-100.sock", "nokcandu-pad-501-abc.sock", "nokcandu-pad-501-100.sock.bak",
                     "nokcandu-pad-501-1.sock", "other-501-100.sock", "nokcandu-pad-501-100x.sock"]
        let stale = PadSocketLeftovers.stale(names, uid: 501) { $0 == 200 }
        XCTAssertEqual(stale, ["nokcandu-pad-501-100.sock", "nokcandu-pad-501-100.sock.buttons"])
        XCTAssertEqual(PadSocketLeftovers.stale(names, uid: 501) { _ in true }, [])
    }
}
