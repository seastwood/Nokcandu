import XCTest
@testable import NokcanduCore

final class ProfileTests: XCTestCase {
    func sample() -> GameProfile {
        GameProfile(title: "Counter-Strike: Source", match: .init(steamAppID: 240), source: "steam", install: nil, graphics: .classic3D,
                    arguments: "-novid -fullscreen +m_rawinput 1", environment: ["DXVK_HUD": "fps"], rawMouse: 1, performance: nil,
                    fixes: nil, rating: .works, tested: nil, notes: "Smooth with raw mouse.")
    }

    func testValidProfileRoundTripsThroughIssueBody() throws {
        let p = sample()
        XCTAssertEqual(p.problems, [])
        let body = "### Profile\n\n```json\n\(p.json())\n```\n\n### Anything else?\n\n_No response_"
        XCTAssertEqual(try GameProfile.parse(body), p)
    }

    func testAudioBufferAndResolutionRoundTrip() throws {
        var p = sample()
        p.audioBuffer = 20; p.displayPixels = [2048, 1280]
        XCTAssertEqual(p.problems, [])
        let body = "### Profile\n\n```json\n\(p.json())\n```"
        XCTAssertEqual(try GameProfile.parse(body), p)
        p.audioBuffer = 15; p.displayPixels = [99999]
        XCTAssertEqual(p.problems.count, 2)
    }

    func testRejectsDangerousSettings() {
        var p = sample()
        p.environment = ["DYLD_INSERT_LIBRARIES": "x", "VK_ICD_FILENAMES": "x", "WINEDLLOVERRIDES": "/tmp/evil", "PATH": "x"]
        p.match = .init(exeName: "../evil.exe")
        p.rawMouse = 50
        let problems = p.problems.joined(separator: "\n")
        for word in ["DYLD_INSERT_LIBRARIES", "VK_ICD_FILENAMES", "PATH", "WINEDLLOVERRIDES", "exeName", "rawMouse"] {
            XCTAssertTrue(problems.contains(word), "expected a problem about \(word):\n\(problems)")
        }
        XCTAssertTrue(GameProfile.envNameAllowed("WINEDLLOVERRIDES"))
        XCTAssertTrue(GameProfile.envNameAllowed("ROSETTA_ADVERTISE_AVX"))
        XCTAssertFalse(GameProfile.envNameAllowed("NOKCANDU_RAW_MOUSE_SCALE"))
        // Paths inside the game's own app are shared portably; anything else isn't.
        XCTAssertTrue(GameProfile.envNameAllowed("CX_APPLEGPTK_LIBD3DSHARED_PATH"))
        XCTAssertTrue(GameProfile.envValueAllowed("{app}/SharedSupport/renderer/d3dmetal/external/libd3dshared.dylib"))
        XCTAssertFalse(GameProfile.envValueAllowed("/Users/x/evil.dylib"))
        XCTAssertFalse(GameProfile.envValueAllowed("{app}/../../evil.dylib"))
        let c = URL(fileURLWithPath: "/Users/x/Applications/Games/Battle.net.app/Contents")
        let portable = Profiles.portable(c.path + "/SharedSupport/renderer/d3dmetal/external/libd3dshared.dylib", contents: c)
        XCTAssertEqual(portable, "{app}/SharedSupport/renderer/d3dmetal/external/libd3dshared.dylib")
        let other = URL(fileURLWithPath: "/Users/y/Applications/Nokcandu Games/Battle.net.app/Contents")
        XCTAssertEqual(Profiles.expand(portable, contents: other), other.path + "/SharedSupport/renderer/d3dmetal/external/libd3dshared.dylib")
        var q = sample(); q.program = #"C:\Games\Warcraft III\Frozen Throne.exe"#; q.drives = ["D"]; q.disc = true; q.hostArguments = "--x"
        XCTAssertEqual(q.problems, [])
        q.program = #"C:\Games\..\x.exe"#
        XCTAssertFalse(q.problems.isEmpty)
    }

    func testSubmitURLCarriesProfile() {
        let u = Profiles.submitURL(sample()).absoluteString
        XCTAssertTrue(u.hasPrefix("https://github.com/seastwood/Nokcandu-Profiles/issues/new?template=game-profile.yml"))
        XCTAssertTrue(u.contains("profile="))
    }

    func testBrokenReports() {
        let e = CatalogEntry(number: 1, url: URL(string: "https://x")!, author: "a", up: 1, down: 4, comments: 0, updated: "", profile: sample())
        XCTAssertTrue(e.reportedBroken)
    }
}

final class ProfileGroupTests: XCTestCase {
    func entry(_ n: Int, _ title: String, steam: Int, up: Int, down: Int, updated: String) -> CatalogEntry {
        CatalogEntry(number: n, url: URL(string: "https://x/\(n)")!, author: "a", up: up, down: down, comments: 0, updated: updated,
                     profile: GameProfile(title: title, match: .init(steamAppID: steam), source: "steam", install: nil, graphics: nil, arguments: nil,
                                          environment: nil, rawMouse: nil, performance: nil, fixes: nil, rating: .works, tested: nil, notes: nil))
    }

    func testGroupsByGameMostLikedFirst() {
        let g = Profiles.groups([
            entry(1, "CS2", steam: 730, up: 1, down: 0, updated: "2026-10-01T00:00:00Z"),
            entry(2, "Counter-Strike 2", steam: 730, up: 9, down: 0, updated: "2026-10-02T00:00:00Z"),
            entry(3, "Counter-Strike 2", steam: 730, up: 0, down: 5, updated: "2026-10-03T00:00:00Z"),
            entry(4, "Portal", steam: 400, up: 3, down: 0, updated: "2026-10-04T00:00:00Z"),
        ])
        XCTAssertEqual(g.map(\.title), ["Counter-Strike 2", "Portal"])
        XCTAssertEqual(g[0].entries.map(\.number), [2, 1, 3])
        XCTAssertEqual(Profiles.groups(g.flatMap(\.entries), sort: .recent).first?.title, "Portal")
    }

    func other(_ n: Int, _ title: String, exe: String?, source: String = "folder") -> CatalogEntry {
        CatalogEntry(number: n, url: URL(string: "https://x/\(n)")!, author: "a", up: 0, down: 0, comments: 0, updated: "2026-10-01T00:00:00Z",
                     profile: GameProfile(title: title, match: .init(exeName: exe), source: source, install: nil, graphics: nil, arguments: nil,
                                          environment: nil, rawMouse: nil, performance: nil, fixes: nil, rating: .works, tested: nil, notes: nil))
    }
    /// One game, one row: whether its profiles start different programs or name it differently.
    func testOneRowPerGame() {
        let entries = [
            other(20, "Battlefield 2", exe: "BF2.exe"), other(21, "Battlefield 2", exe: "bf2hub.exe"),
            other(22, "Battlefield 1942 (Moongamers)", exe: "BF1942.exe"),
            other(30, "Warcraft III", exe: "war3.exe"), other(31, "WC3: Reign of Chaos", exe: "War3.exe"),
            other(40, "Alpha", exe: "game.exe"), other(41, "Beta", exe: "Game.exe"),
            other(50, "Battlefield: Bad Company\\x2122 2", exe: "BFBC2Game.exe"), other(51, "battlefield bad company™ 2", exe: nil),
        ]
        let g = Profiles.groups(entries, sort: .name)
        XCTAssertEqual(g.map { $0.entries.map(\.number).sorted() }.sorted { $0[0] < $1[0] }, [[20, 21], [22], [30, 31], [40], [41], [50, 51]])
        XCTAssertEqual(Set(g.map(\.id)).count, g.count)
        let bf2 = try! XCTUnwrap(Profiles.group(of: entries[1], in: g))
        XCTAssertEqual(bf2.title, "Battlefield 2"); XCTAssertEqual(bf2.entries.count, 2)
        // The same rows and ids whatever order the catalog comes in.
        XCTAssertEqual(Set(Profiles.groups(entries.reversed(), sort: .name).map(\.id)), Set(g.map(\.id)))
        XCTAssertEqual(Profiles.cleanTitle("Battlefield: Bad Company\\x2122 2"), "Battlefield: Bad Company™ 2")
        XCTAssertEqual(Profiles.cleanTitle("Plain"), "Plain")
    }
}

final class MyProfilesTests: XCTestCase {
    func testRejectsUnsafeImports() {
        XCTAssertThrowsError(try MyProfiles.importText(#"{"schema":1,"title":"x","match":{"steamAppID":1},"source":"steam","rating":"works","environment":{"DYLD_INSERT_LIBRARIES":"x"}}"#))
    }
}
