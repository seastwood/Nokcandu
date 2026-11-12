import XCTest
import NokcanduPadEngine
@testable import NokcanduCore
final class PadOverhaulProfileTests: XCTestCase {
    func testNewFeaturesRoundTripAndBackupDoesNotOverwriteOriginal() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("profiles.json")
        var p = PadProfiles.Profile(name: "Keep settings")
        p.base[.a] = .as(.key(12))
        try PadProfiles.saveProfiles([p], file: file)
        let original = try Data(contentsOf: file)
        p.base[.a] = .as(.keyToggle(12)); p.base[.b] = .as(.mouseToggle(.right))
        p.routingMode = .selective; p.buttonRoutes = ["a": .both]
        try PadProfiles.saveProfiles([p], file: file)
        XCTAssertEqual(PadProfiles.profiles(file: file), [p])
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), original)
        p.name = "Edited again"; try PadProfiles.saveProfiles([p], file: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), original)
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains("route a both"))
        p.routingMode = .native
        XCTAssertEqual(PadProfiles.compile(p, all: [p]), "nokpad 1\n")
    }
    func testLegacyMacroTimingStaysUnchangedAndNewSequencesCancelCleanly() throws {
        let old = Data(#"{"id":"old","name":"Old","steps":[{"kind":"down","output":"key:12"},{"kind":"up","output":"key:12"}]}"#.utf8)
        let legacy = try JSONDecoder().decode(PadProfiles.Macro.self, from: old)
        XCTAssertNil(legacy.eventDelayMS)
        var chord = PadProfiles.Macro.Step(.chord)
        chord.outputs = [.key(55), .key(48)]
        let macro = PadProfiles.Macro(name: "Shortcut", steps: [chord, .init(.down, output: .mouse(.left)), .init(.wait, ms: 500), .init(.up, output: .mouse(.left))])
        var p = PadProfiles.Profile(name: "Sequences")
        p.macros = [macro]; p.base[.a] = .as(.macro(macro.id))
        let compiled = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(compiled.contains("down:key:55 down:key:48 wait:30 up:key:48 up:key:55 wait:50 down:mouse:left"))
        let r = PadRecorder(String(compiled.dropFirst("nokpad 1\n".count)))
        r.press("a", true, 1); r.tick(1.04); r.tick(1.10)
        XCTAssertEqual(r.take(), ["key 55 down", "key 48 down", "key 48 up", "key 55 up", "mouse 0 down"])
        pe_release_all(r.engine, 1.2)
        XCTAssertEqual(r.take(), ["mouse 0 up"])
        r.tick(10); XCTAssertTrue(r.take().isEmpty)
    }
    func testZeroDelaySequenceDoesNotBlockInput() {
        let r = PadRecorder("macro 0 down:key:12 wait:0 up:key:12\nbind 0 a press=macro:0\nbind 0 b press=key:13")
        r.press("a", true, 1); r.tick(1.001)
        r.press("b", true, 1.01); r.press("b", false, 1.02)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up", "key 13 down", "key 13 up"])
    }
}

final class PadControlRouteProfileTests: XCTestCase {
    func testInheritedRoutesCompileAndChildOverridesRoundTrip() throws {
        var parent = PadProfiles.Profile(name: "Parent")
        parent.routingMode = .selective
        parent.controlRoutes = ["lstick": .native, "rstick": .both, "gyro": .mapped, "rt": .disabled]
        var child = PadProfiles.Profile(name: "Child", buildsOn: [parent.id])
        child.controlRoutes = ["rt": .both]
        let text = PadProfiles.compile(child, all: [parent, child])
        for line in ["route lstick native", "route rstick both", "route gyro mapped", "route rt both"] { XCTAssertTrue(text.contains(line)) }
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(child)), child)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("profiles.json")
        try PadProfiles.saveProfiles([PadProfiles.Profile(name: "Legacy")], file: file)
        let old = try Data(contentsOf: file)
        try PadProfiles.saveProfiles([child], file: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), old)
    }
}

final class PadPrimaryRoutingModeTests: XCTestCase {
    func testNewPrimaryModesAreExplicitAndOldButtonOnlyModesStayScoped() {
        var p = PadProfiles.Profile(name: "Modes")
        for (mode, route) in [(PadProfiles.RoutingMode.hybridAll, "both"), (.remappingAll, "mapped")] {
            p.routingMode = mode
            let compiled = PadProfiles.compile(p, all: [p])
            for key in ["a", "lstick", "rstick", "lt", "rt", "gyro", "touch", "tilt"] { XCTAssertTrue(compiled.contains("route \(key) \(route)")) }
        }
        p.routingMode = .hybrid
        let old = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(old.contains("route a both")); XCTAssertFalse(old.contains("route lstick"))
    }
}

final class PadToggleBehaviorProfileTests: XCTestCase {
    func testVisibleToggleBehaviorRoundTripsAndCompilesAllHeldOutputKinds() throws {
        var p = PadProfiles.Profile(name: "Toggle behavior")
        var b = PadProfiles.Binding(press: [.key(12), .mouse(.left), .pad(.b), .trigger(right: true)], turbo: 100)
        b.togglePress = true; p.base[.a] = b
        let encoded = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PadProfiles.Profile.self, from: encoded)
        XCTAssertEqual(decoded, p)
        let text = PadProfiles.compile(decoded, all: [decoded])
        XCTAssertTrue(text.contains("press=keytoggle:12,mousetoggle:left,padtoggle:b,trigtoggle:r"))
        XCTAssertFalse(text.contains("turbo=100"))
        let r = PadRecorder(text.replacingOccurrences(of: "nokpad 1\n", with: ""))
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(Set(r.take()), Set(["key 12 down", "mouse 0 down", "pad b down"]))
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 32767)
        r.press("a", true, 2); r.press("a", false, 2.01)
        XCTAssertEqual(Set(r.take()), Set(["key 12 up", "mouse 0 up", "pad b up"]))
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 0)
    }
    func testOldExplicitToggleRemainsRecognizableAndHeldConversionIsReversible() throws {
        let output: [PadProfiles.Output] = [.key(12), .mouse(.right), .pad(.a), .trigger(right: false)]
        for value in output {
            let toggled = try XCTUnwrap(value.toggledOutput)
            XCTAssertTrue(toggled.isHeldToggle)
            XCTAssertEqual(toggled.heldOutput, value)
            XCTAssertEqual(PadProfiles.Output(token: toggled.token), toggled)
        }
        let legacy = PadProfiles.Binding.as(.keyToggle(12))
        XCTAssertTrue(legacy.togglesOnPress)
        XCTAssertNil(legacy.togglePress)
        XCTAssertFalse(PadProfiles.Binding(press: [.keyToggle(12), .key(13)]).togglesOnPress)
    }
    func testUnsupportedToggleOutputCannotFallBackToNativeButton() {
        var p = PadProfiles.Profile(name: "Invalid toggle")
        var b = PadProfiles.Binding.as(.wheel(up: true)); b.togglePress = true; p.base[.a] = b
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains("bind 0 a press=none"))
    }
    func testToggleOnlyMetadataTriggersPreV2Backup() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("profiles.json")
        var p = PadProfiles.Profile(name: "Toggle")
        p.base[.a] = .as(.key(12)); try PadProfiles.saveProfiles([p], file: file)
        let original = try Data(contentsOf: file)
        var b = p.base[.a]!; b.togglePress = true; p.base[.a] = b
        try PadProfiles.saveProfiles([p], file: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), original)
    }
}
