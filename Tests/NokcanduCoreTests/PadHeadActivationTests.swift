import XCTest
import NokcanduCore
import NokcanduPadEngine

final class PadHeadActivationTests: XCTestCase {
    func testExistingHeadProfilesKeepAlwaysActiveDefaultAndRoundTripNewSelection() throws {
        let old = try JSONDecoder().decode(PadHeadMotionSettings.self, from: Data("{\"enabled\":true,\"sensitivity\":2400}".utf8))
        XCTAssertEqual(old.activation, .always)
        XCTAssertTrue(old.permitsMotion(held: [], layer: "Base"))
        let selected = PadHeadMotionSettings(activation: .whileHeld, activationButton: .rb, activationLayer: "Fine Aim")
        XCTAssertEqual(try JSONDecoder().decode(PadHeadMotionSettings.self, from: JSONEncoder().encode(selected)), selected)
        XCTAssertEqual(selected.normalized.activation, .whileHeld)
        XCTAssertEqual(selected.normalized.activationButton, .rb)
    }
    func testPhysicalHoldIsIndependentOfOtherButtonsAndFailsClosedForUnsupportedInput() {
        var settings = PadHeadMotionSettings(activation: .whileHeld, activationButton: .lb)
        XCTAssertFalse(settings.permitsMotion(held: [], layer: "Base"))
        XCTAssertFalse(settings.permitsMotion(held: [.a], layer: "Base"))
        XCTAssertTrue(settings.permitsMotion(held: [.a, .lb], layer: "Base"))
        XCTAssertFalse(settings.permitsMotion(held: [.a], layer: "Base"))
        settings.activationButton = .tiltleft
        XCTAssertFalse(settings.permitsMotion(held: [.tiltleft], layer: "Base"))
    }
    func testSelectedLayerWorksWithRealHoldAndToggleWithoutDisablingControllerGyro() {
        let r = PadRecorder("gyro out=mouse on=1 cal=off\nbind 0 lb press=layer:hold:1\nbind 0 rb press=layer:toggle:1")
        let names = ["Base", "Fine Aim"]
        let settings = PadHeadMotionSettings(activation: .inLayer, activationLayer: "Fine Aim")
        func active() -> Bool { settings.permitsMotion(held: [], layer: names[Int(pe_active_layer(r.engine))]) }
        XCTAssertFalse(active())
        r.press("lb", true, 1); XCTAssertTrue(active())
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
        r.press("lb", false, 1.1); XCTAssertFalse(active())
        r.press("rb", true, 2); r.press("rb", false, 2.1); XCTAssertTrue(active())
        r.press("rb", true, 3); r.press("rb", false, 3.1); XCTAssertFalse(active())
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
    }
    func testMissingLayerAndDisabledSourceCannotActivate() {
        var s = PadHeadMotionSettings(activation: .inLayer, activationLayer: "Fine Aim")
        XCTAssertTrue(s.permitsMotion(held: [], layer: "fine aim"))
        XCTAssertFalse(s.permitsMotion(held: [], layer: "Fine Aim Extra"))
        XCTAssertFalse(s.permitsMotion(held: [], layer: nil))
        s.activationLayer = ""; XCTAssertFalse(s.permitsMotion(held: [], layer: "Base"))
        s.activation = .always; s.enabled = false
        XCTAssertFalse(s.permitsMotion(held: [.lb], layer: "Base"))
        s.enabled = true; s.included = false
        XCTAssertFalse(s.permitsMotion(held: [.lb], layer: "Base"))
    }
    func testHoldActivationDiscardsInactiveMovementAndReactivationDoesNotJump() {
        let s = PadHeadMotionSettings(activation: .whileHeld, activationButton: .lb)
        var motion = PadHeadMotion()
        func sample(_ yaw: Double, held: Set<PadProfiles.Input>) -> Int {
            motion.sample(yaw: yaw, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1,
                          active: s.permitsMotion(held: held, layer: "Base")).0
        }
        XCTAssertEqual(sample(0, held: []), 0)
        XCTAssertEqual(sample(0.3, held: []), 0)
        XCTAssertEqual(sample(0.4, held: [.lb]), 0)
        XCTAssertNotEqual(sample(0.41, held: [.lb]), 0)
        XCTAssertEqual(sample(0.5, held: []), 0)
        XCTAssertEqual(sample(0.7, held: [.lb]), 0)
    }
}
