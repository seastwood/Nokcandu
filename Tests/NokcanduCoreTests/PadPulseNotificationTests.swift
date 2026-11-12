import XCTest
@testable import NokcanduCore
final class PadPulseNotificationTests: XCTestCase {
    func testPulseSpacingIsIndependentAndBounded() throws {
        let tight=try XCTUnwrap(SteamControllerHaptics.pulse(side:1,strength:0.4,spacingMS:0.25))
        let wide=try XCTUnwrap(SteamControllerHaptics.pulse(side:1,strength:0.4,spacingMS:3))
        XCTAssertEqual(Array(tight[3...4]),Array(wide[3...4]))
        XCTAssertEqual(Array(tight[5...6]),[250,0])
        XCTAssertEqual(Array(wide[5...6]),[0xb8,0x0b])
        XCTAssertEqual(wide[7],3)
        XCTAssertEqual(SteamControllerHaptics.pulse(side:1,strength:0.4,spacingMS:.nan),SteamControllerHaptics.pulse(side:1,strength:0.4))
        XCTAssertEqual(SteamControllerHaptics.pulse(side:1,strength:0.4,spacingMS:100),wide)
    }
    func testRepeatRateIsPerPadAndDoesNotChangePulseStrength() {
        var feedback=SteamControllerHaptics()
        let first=feedback.movement(side:1,dx:1,dy:0,strength:0.4,rate:10,spacingMS:0.25,at:1)
        XCTAssertNotNil(first)
        XCTAssertNil(feedback.movement(side:1,dx:1,dy:0,strength:0.4,rate:10,spacingMS:0.25,at:1.05))
        XCTAssertNotNil(feedback.movement(side:0,dx:1,dy:0,strength:0.4,rate:40,at:1.05))
        XCTAssertEqual(feedback.movement(side:1,dx:1,dy:0,strength:0.4,rate:10,spacingMS:0.25,at:1.11),first)
        XCTAssertNil(feedback.movement(side:1,dx:1,dy:0,strength:0.4,rate:1000,at:1.12))
    }
    func testMovementMatchedPulsesFollowDistanceAndRespectRateLimit() {
        func count(_ step: Int) -> Int {
            var feedback = SteamControllerHaptics()
            return (0..<100).reduce(0) { total, tick in
                total + (feedback.movement(side:1,dx:step,dy:0,strength:0.4,rate:40,followsMovement:true,at:Double(tick)*0.01) == nil ? 0 : 1)
            }
        }
        XCTAssertGreaterThan(count(8), count(1))
        XCTAssertLessThanOrEqual(count(100), 40)
        var feedback = SteamControllerHaptics()
        XCTAssertNil(feedback.movement(side:1,dx:8,dy:0,strength:0.4,followsMovement:true,at:1))
        XCTAssertNotNil(feedback.movement(side:1,dx:0,dy:-8,strength:0.4,followsMovement:true,at:1.01))
        XCTAssertNil(feedback.movement(side:0,dx:8,dy:0,strength:0.4,followsMovement:true,at:1.02))
        XCTAssertNil(feedback.movement(side:0,dx:8,dy:0,strength:0.4,followsMovement:true,at:2)) // idle discards partial travel
        feedback.reset()
        XCTAssertNil(feedback.movement(side:1,dx:8,dy:0,strength:0.4,followsMovement:true,at:3))
        XCTAssertNil(feedback.movement(side:1,dx:0,dy:0,strength:0.4,followsMovement:true,at:4))
    }
    func testGyroNotificationPreferenceKeepsLegacyMasterAndOtherChoices() throws {
        let name="NokcanduNoticeTest."+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        XCTAssertTrue(PadNotificationPreferences.shouldShowGyro(defaults))
        defaults.set(true,forKey:"padAutomaticCalibrationNotifications")
        PadNotificationPreferences.setGyroSwitches(false,defaults:defaults)
        XCTAssertFalse(PadNotificationPreferences.shouldShowGyro(defaults))
        XCTAssertFalse(defaults.bool(forKey:"padHUDOff"))
        XCTAssertTrue(defaults.bool(forKey:"padAutomaticCalibrationNotifications"))
        defaults.set(true,forKey:"padHUDOff")
        PadNotificationPreferences.setGyroSwitches(true,defaults:defaults)
        XCTAssertFalse(PadNotificationPreferences.shouldShowGyro(defaults))
        defaults.set(false,forKey:"padHUDOff")
        XCTAssertTrue(PadNotificationPreferences.shouldShowGyro(defaults))
    }
    func testPulseTuningOptionalFieldsKeepOlderProfileValues() throws {
        var settings=PadSteamTrackpadSettings(mode:.trackball)
        settings.hapticFollowsMovement=true;settings.hapticRate=12;settings.hapticSpacingMS=0.4;settings.movementFeedback=0.25
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
}
