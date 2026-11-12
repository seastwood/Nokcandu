import XCTest
import NokcanduCore

final class PadOutputRecorderTests: XCTestCase {
    func testEscapeCancelsWithoutAddingOutputOrLeakingModifiers() {
        var recorder = PadOutputRecorder()
        XCTAssertEqual(recorder.receive(.modifier(55, down: true)), .waiting)
        XCTAssertEqual(recorder.receive(.key(53)), .cancelled)
        XCTAssertEqual(recorder.receive(.key(12)), .outputs([.key(12)]))
    }
    func testChordOrdersModifiersAndResetEndsOldSession() {
        var recorder = PadOutputRecorder()
        _ = recorder.receive(.modifier(59, down: true)); _ = recorder.receive(.modifier(55, down: true))
        XCTAssertEqual(recorder.receive(.key(48)), .outputs([.key(55), .key(59), .key(48)]))
        _ = recorder.receive(.modifier(56, down: true)); recorder.reset()
        XCTAssertEqual(recorder.receive(.key(12)), .outputs([.key(12)]))
    }
    func testMouseExtraButtonsAndWheelRejectUnsupportedInput() {
        var recorder = PadOutputRecorder()
        XCTAssertEqual(recorder.receive(.mouseButton(2)), .outputs([.mouse(.middle)]))
        XCTAssertEqual(recorder.receive(.mouseButton(3)), .outputs([.mouse(.back)]))
        XCTAssertEqual(recorder.receive(.mouseButton(4)), .outputs([.mouse(.forward)]))
        XCTAssertEqual(recorder.receive(.mouseButton(5)), .waiting)
        XCTAssertEqual(recorder.receive(.wheel(.nan)), .waiting)
        XCTAssertEqual(recorder.receive(.wheel(0.1)), .waiting)
        XCTAssertEqual(recorder.receive(.wheel(-1)), .outputs([.wheel(up: false)]))
    }
    func testRecordedOutputsUseSameToggleConversionAsTheMenu() {
        var recorder = PadOutputRecorder()
        guard case .outputs(let outputs) = recorder.receive(.key(12)) else { return XCTFail("Missing output") }
        XCTAssertEqual(outputs.compactMap(\.toggledOutput), [.keyToggle(12)])
    }
}
