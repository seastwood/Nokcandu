import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

/// Which controller is which: remembered controllers, players, the order profiles are chosen in, and what Windows
/// games' controller driver reads.
final class ControllerRosterTests: XCTestCase {
    func testSerialsAgreeAcrossSpellingsAndPlaceholdersAreIgnored() {
        XCTAssertEqual(ControllerRoster.normalizedSerial("A4-AE-12-3B-4C-5D"), "a4ae123b4c5d")
        XCTAssertEqual(ControllerRoster.normalizedSerial("a4ae123b4c5d"), "a4ae123b4c5d")
        XCTAssertNil(ControllerRoster.normalizedSerial(nil))
        XCTAssertNil(ControllerRoster.normalizedSerial(""))
        XCTAssertNil(ControllerRoster.normalizedSerial("000000000001"), "a counter, not a serial")
        XCTAssertNil(ControllerRoster.normalizedSerial("ffffffffffff"))
        XCTAssertNil(ControllerRoster.normalizedSerial("12345"), "too short to tell controllers apart")
    }

    func testKeysUseTheSerialOrElseThePlace() {
        XCTAssertEqual(ControllerRoster.key(vendorID: 0x057E, productID: 0x2009, serial: "98-B6-E9-01-02-03", nth: 1), "057e:2009:s:98b6e9010203")
        XCTAssertEqual(ControllerRoster.key(vendorID: 0x057E, productID: 0x2009, serial: nil, nth: 1), "057e:2009:n:1")
    }

    func testSeeingAControllerRemembersItOnce() {
        var r = ControllerRoster()
        let k = r.saw(vendorID: 0x054C, productID: 0x05C4, serial: "aa-bb-cc-dd-ee-ff", nth: 0, name: "Wireless Controller")
        r.update(k) { $0.customName = "Seth's DS4"; $0.seat = .player(2) }
        XCTAssertEqual(r.saw(vendorID: 0x054C, productID: 0x05C4, serial: "AABBCCDDEEFF", nth: 3, name: "Wireless Controller"), k)
        XCTAssertEqual(r.controllers.count, 1)
        XCTAssertEqual(r.controller(k)?.name, "Seth's DS4")
        XCTAssertEqual(r.controller(k)?.seat, .player(2))
        XCTAssertFalse(r.controller(k)!.byOrder)
        let twin = r.saw(vendorID: 0x054C, productID: 0x05C4, serial: nil, nth: 1, name: "Wireless Controller")
        XCTAssertTrue(r.controller(twin)!.byOrder)
        r.forget(twin)
        XCTAssertNil(r.controller(twin))
    }

    func testAutoControllersTakeTheFreePlayersInOrder() {
        var r = ControllerRoster()
        let a = r.saw(vendorID: 1, productID: 1, serial: "aaaaaa111111", nth: 0, name: "A")
        let b = r.saw(vendorID: 1, productID: 1, serial: "bbbbbb222222", nth: 1, name: "B")
        let c = r.saw(vendorID: 1, productID: 1, serial: "cccccc333333", nth: 2, name: "C")
        XCTAssertEqual(r.players(connected: [a, b, c]), [a: 1, b: 2, c: 3], "nothing set: the order they connected")
        r.update(c) { $0.seat = .player(1) }
        XCTAssertEqual(r.players(connected: [a, b, c]), [c: 1, a: 2, b: 3], "one set to player 1 moves the others up")
        r.update(a) { $0.seat = .player(1) }
        XCTAssertEqual(r.players(connected: [a, b, c]), [c: 1, a: 1, b: 2], "two on one player drive it together")
        r.update(b) { $0.seat = .player(4) }
        XCTAssertEqual(r.players(connected: [a, b, c])[b], 4)
    }

    func testProfilesAreChosenInOneFixedOrder() {
        func pick(everywhere: String? = nil, game: String? = nil, forController: String? = nil, gameProfile: String? = nil,
                  rule: String? = nil, own: String? = nil, mac: String? = nil) -> (String?, ControllerRoster.Reason) {
            let r = ControllerRoster.resolve(everywhere: everywhere, game: game, gameForController: forController, gameProfile: gameProfile,
                                             appName: "Blender", appRule: rule, controllerFallback: own, macDefault: mac)
            return (r.id, r.reason)
        }
        XCTAssertEqual(pick(everywhere: "e", game: "Noita", forController: "c", gameProfile: "g").0, "e")
        XCTAssertEqual(pick(game: "Noita", forController: "c", gameProfile: "g", own: "o").1, .gameForController("Noita"))
        XCTAssertEqual(pick(game: "Noita", gameProfile: "g", own: "o").0, "g")
        let none = pick(game: "Noita", own: "o", mac: "m")
        XCTAssertNil(none.0, "a game without a profile keeps controllers as they are; the controller's own profile is for other apps")
        XCTAssertEqual(none.1, .gameNone("Noita"))
        XCTAssertEqual(pick(rule: "r", own: "o", mac: "m").0, "r")
        XCTAssertEqual(pick(rule: "off", own: "o").0, nil)
        XCTAssertEqual(pick(own: "o", mac: "m").1, .controllerFallback)
        XCTAssertEqual(pick(mac: "m").1, .macDefault)
        XCTAssertEqual(pick().1, .none)
        XCTAssertEqual(ControllerRoster.Reason.gameForController("Noita").words, "Noita's choice for this controller")
    }

    func testPlayersFileForWindowsGames() {
        var r = ControllerRoster()
        let a = r.saw(vendorID: 0x057E, productID: 0x2009, serial: "98-B6-E9-01-02-03", nth: 0, name: "Pro Controller")
        let b = r.saw(vendorID: 0x045E, productID: 0x0B13, serial: nil, nth: 0, name: "Xbox")
        r.update(b) { $0.seat = .player(2) }
        let text = r.playersText(connected: [
            .init(key: a, registryID: 4294970234, vendorID: 0x057E, productID: 0x2009, serial: "98-B6-E9-01-02-03", nth: 0),
            .init(key: b, registryID: 4294970300, vendorID: 0x045E, productID: 0x0B13, serial: nil, nth: 0),
        ])
        XCTAssertEqual(text, "nokplayers 1\nc 4294970234 1406 8201 98b6e9010203 0 0 \(a)\nc 4294970300 1118 2835 - 0 2 \(b)\n")
        let seen = "pid 4242\n\(a) 1\n\(b) 2\n"
        XCTAssertEqual(ControllerRoster.parseSeen(seen), [a: 1, b: 2])
        XCTAssertEqual(ControllerRoster.seenProcess(seen), 4242)
        XCTAssertNil(ControllerRoster.seenProcess("\(a) 1\n"))
    }

    func testRosterSavesAndLoads() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("roster-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: f) }
        var r = ControllerRoster()
        let k = r.saw(vendorID: 1, productID: 2, serial: "abcdef123456", nth: 0, name: "Pad")
        r.update(k) { $0.fallbackProfileID = "p"; $0.seat = .player(3) }
        r.save(to: f)
        XCTAssertEqual(ControllerRoster.load(from: f), r)
        XCTAssertEqual(ControllerRoster.load(from: f.appendingPathExtension("missing")), ControllerRoster())
    }

    // MARK: A game's choices for particular controllers

    func testPerControllerProfilesCompileIntoBlocksTheEngineSkips() {
        var game = PadProfiles.Profile(id: "g", name: "Game"); game.layers[0][.a] = PadProfiles.Binding(press: [.key(12)])
        var pro = PadProfiles.Profile(id: "p", name: "Pro"); pro.layers[0][.a] = PadProfiles.Binding(press: [.key(13)])
        let all = [game, pro]
        let text = PadProfiles.compile(game, controllers: ["057e:2009:s:98b6e9010203": "p", "x:y:n:0": "missing"], all: all)!
        XCTAssertTrue(text.hasPrefix(PadProfiles.compile(game, all: all)), "the game's own profile comes first, unchanged")
        XCTAssertTrue(text.contains("controller 057e:2009:s:98b6e9010203 begin\nnokpad 1\n"))
        XCTAssertTrue(text.hasSuffix("controller 057e:2009:s:98b6e9010203 end\n"))
        XCTAssertFalse(text.contains("x:y:n:0"), "a profile that's gone is left out")
        // The engine runs the game's profile, not the controller's block.
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.1)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up"])
        // Without a game profile, the blocks alone (the controller as it is otherwise).
        XCTAssertEqual(PadProfiles.compile(nil, controllers: ["k": "p"], all: all)?.hasPrefix("nokpad 1\ncontroller k begin\n"), true)
        XCTAssertNil(PadProfiles.compile(nil, controllers: [:], all: all))
        XCTAssertEqual(PadProfiles.compile(game, controllers: [:], all: all), PadProfiles.compile(game, all: all), "nothing changes without choices")
    }

    func testPerControllerChoicesAreStoredWithTheGame() throws {
        let contents = FileManager.default.temporaryDirectory.appendingPathComponent("contents-\(UUID().uuidString)")
        let profilesFile = contents.appendingPathComponent("profiles.json"), defaultFile = contents.appendingPathComponent("default")
        defer { try? FileManager.default.removeItem(at: contents) }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PadProfiles.setControllerChoice("p1", controller: "057e:2009:n:0", contents: contents, file: profilesFile, defaultFile: defaultFile)
        try PadProfiles.setControllerChoice("p2", controller: "045e:0b13:s:abcdef123456", contents: contents, file: profilesFile, defaultFile: defaultFile)
        XCTAssertEqual(PadProfiles.controllerChoices(contents: contents), ["057e:2009:n:0": "p1", "045e:0b13:s:abcdef123456": "p2"])
        try PadProfiles.setControllerChoice(nil, controller: "057e:2009:n:0", contents: contents, file: profilesFile, defaultFile: defaultFile)
        XCTAssertEqual(PadProfiles.controllerChoices(contents: contents), ["045e:0b13:s:abcdef123456": "p2"])
        try PadProfiles.setControllerChoice(nil, controller: "045e:0b13:s:abcdef123456", contents: contents, file: profilesFile, defaultFile: defaultFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PadProfiles.controllerChoicesFile(contents).path))
        XCTAssertThrowsError(try PadProfiles.setControllerChoice("p", controller: "bad key", contents: contents, file: profilesFile, defaultFile: defaultFile))
    }
}
