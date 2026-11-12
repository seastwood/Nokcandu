import XCTest
import NokcanduCore

final class PadInputObservationTests: XCTestCase {
    func testToggleAndRepeatRemainHeldUntilObservedRelease() {
        var state = PadInputObservation(start: 10)
        state.receive(.key(49, down: true, repeated: false), mapped: true, at: 11)
        state.receive(.key(49, down: true, repeated: true), mapped: true, at: 12)
        XCTAssertEqual(state.keys, [49])
        state.receive(.key(12, down: true, repeated: false), mapped: false, at: 13)
        state.receive(.key(49, down: false, repeated: false), mapped: true, at: 14)
        XCTAssertEqual(state.keys, [12])
        XCTAssertEqual(state.history.map(\.seconds), [1, 2, 3, 4])
        XCTAssertEqual(state.history.map(\.mapped), [true, true, false, true])
    }
    func testIndependentButtonsAndUnmatchedRelease() {
        var state = PadInputObservation(start: 0)
        state.receive(.button(0, down: true), mapped: true, at: 1)
        state.receive(.button(1, down: true), mapped: true, at: 2)
        state.receive(.button(0, down: false), mapped: true, at: 3)
        state.receive(.button(4, down: false), mapped: true, at: 4)
        XCTAssertEqual(state.buttons, [1])
    }
    func testFocusLossInvalidatesRatherThanClaimingReleaseAndResetStartsNewTrial() {
        var state = PadInputObservation(start: 0)
        state.receive(.key(49, down: true, repeated: false), mapped: true, at: 1)
        state.receive(.button(0, down: true), mapped: true, at: 2)
        state.receive(.modifiers(123), mapped: true, at: 3)
        state.receive(.interrupted, mapped: false, at: 4)
        XCTAssertTrue(state.interrupted)
        XCTAssertTrue(state.keys.isEmpty); XCTAssertTrue(state.buttons.isEmpty)
        XCTAssertEqual(state.modifierFlags, 0)
        XCTAssertEqual(state.history.last?.input, .interrupted)
        state.receive(.key(12, down: true, repeated: false), mapped: false, at: 5)
        XCTAssertTrue(state.interrupted, "Only explicit Reset starts a complete new trial")
        state.reset(at: 10)
        XCTAssertFalse(state.interrupted); XCTAssertTrue(state.history.isEmpty); XCTAssertTrue(state.keys.isEmpty)
    }
    func testBoundedHistoryRejectsInvalidControlsAndHandlesInvalidTime() {
        var state = PadInputObservation(start: 10)
        state.receive(.key(-1, down: true, repeated: false), mapped: true, at: 11)
        state.receive(.button(32, down: true), mapped: true, at: 11)
        XCTAssertTrue(state.history.isEmpty)
        for i in 0..<100 { state.receive(.button(0, down: i % 2 == 0), mapped: true, at: Double(i) + 10) }
        XCTAssertEqual(state.history.count, 32)
        state.receive(.modifiers(0), mapped: false, at: .nan)
        XCTAssertEqual(state.history.last?.seconds, 99)
        state.receive(.modifiers(0), mapped: false, at: 1)
        XCTAssertEqual(state.history.last?.seconds, 99)
    }
}
