import XCTest
@testable import NokcanduCore

final class PadHeadProfileTests: XCTestCase {
    func testOldProfileStaysOptedOutAndSettingsRoundTrip() throws {
        let old = PadProfiles.Profile(name: "Existing")
        XCTAssertNil(try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(old)).headMotion)
        var changed = old
        changed.headMotion = PadHeadMotionSettings(sensitivity: 2400, smoothing: 0.2, deadZone: 0.003, invertX: true)
        let restored = try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored.headMotion, changed.headMotion)
        XCTAssertEqual(PadProfiles.compile(old, all: [old]), PadProfiles.compile(changed, all: [changed]), "Head source does not invent a Wine HID/controller output")
    }
    func testInheritedHeadSourceCanBeDisabledWithoutChangingParent() {
        var parent = PadProfiles.Profile(id: "parent", name: "Parent")
        parent.headMotion = PadHeadMotionSettings(sensitivity: 2100)
        var child = PadProfiles.Profile(name: "Child", buildsOn: [parent.id])
        XCTAssertEqual(PadProfiles.headMotion(child, all: [parent, child])?.sensitivity, 2100)
        child.headMotion = PadHeadMotionSettings(enabled: false)
        XCTAssertEqual(PadProfiles.headMotion(child, all: [parent, child])?.enabled, false)
        XCTAssertEqual(parent.headMotion?.enabled, true)
        child.headMotion = nil
        XCTAssertEqual(PadProfiles.headMotion(child, all: [parent, child])?.sensitivity, 2100)
    }
    func testRemovingInheritedSourceAndUnrelatedProfileStayOptedOut() {
        var parent = PadProfiles.Profile(id: "parent", name: "Parent")
        parent.headMotion = PadHeadMotionSettings()
        var child = PadProfiles.Profile(name: "Child", buildsOn: [parent.id])
        child.headMotion = PadHeadMotionSettings(included: false, enabled: false)
        let unrelated = PadProfiles.Profile(name: "Other")
        XCTAssertEqual(PadProfiles.headMotion(child, all: [parent, child])?.included, false)
        XCTAssertNil(PadProfiles.headMotion(unrelated, all: [parent, child, unrelated]))
        XCTAssertEqual(parent.headMotion?.included, true)
    }
    func testImportedPartialSettingsHaveSafeDefaultsAndBounds() throws {
        let partial = try JSONDecoder().decode(PadHeadMotionSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(partial, PadHeadMotionSettings())
        let bounded = PadHeadMotionSettings(sensitivity: .infinity, smoothing: -3, deadZone: 99).normalized
        XCTAssertEqual(bounded.sensitivity, 1200)
        XCTAssertEqual(bounded.smoothing, 0.05)
        XCTAssertEqual(bounded.deadZone, 0.01)
    }
    func testFirstHeadSourceSavePreservesOriginalProfileBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json")
        var p = PadProfiles.Profile(name: "Existing")
        try PadProfiles.saveProfiles([p], file: file)
        let original = try Data(contentsOf: file)
        p.headMotion = PadHeadMotionSettings()
        try PadProfiles.saveProfiles([p], file: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), original)
        p.headMotion?.sensitivity = 3000
        try PadProfiles.saveProfiles([p], file: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), original)
    }
}
