import XCTest
@testable import NokcanduCore

final class CrashReportTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-crash-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static let fhsw = #"""
    WineDbg attached to pid 033c
    Unhandled exception: page fault on read access to 0x00000004 in wow64 32-bit code (0x00446314).
    Register dump:
     EIP:00446314 ESP:00b9c1f8 EBP:00000016 EFLAGS:00000216(   - --  I   -A-P- )
    Backtrace:
    =>0 0x00446314 in bf1942 (+0x46314) (0x00000016)
    0x00446314 bf1942+0x46314: movl 4(%eax), %esi
    Modules:
    PE        400000-  a96000       --none--        bf1942
    Threads:
    0000033c (D) C:\Games\EA Games\Battlefield 1942 (Moongamers)\BF1942.exe
    	[BF1942.exe +game FHSW +restart 1 +goToInterface 8]
    	00000340    0 <==
    """#

    func makeMods(_ mods: [String: String]) throws -> URL {
        let game = root.appendingPathComponent("Battlefield 1942")
        for (name, initText) in mods {
            let dir = game.appendingPathComponent("Mods/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(initText.utf8).write(to: dir.appendingPathComponent("init.con"))
        }
        return game
    }

    func testMissingModDependenciesAreFoundCaseInsensitively() throws {
        let game = try makeMods([
            "FHSW": "game.SetCustomGameName FHSW\r\ngame.addmodPath Mods/FHSW/\r\ngame.addModPath Mods/FH/\r\ngame.addModPath Mods/Bf1942/\r\n",
            "bf1942": "game.addModPath Mods/bf1942/\n",
            "DesertCombat": "rem game.addModPath Mods/Nothing/\ngame.addModPath \"mods/BF1942/\"\n",
        ])
        let missing = ModDependencies.missing(root: game)
        XCTAssertEqual(missing.map(\.mod), ["FHSW"])
        XCTAssertEqual(missing.first?.needs, ["FH"])
        XCTAssertTrue(missing.first?.message.contains("Forgotten Hope (Mods/FH)") == true)
        try FileManager.default.createDirectory(at: game.appendingPathComponent("Mods/fh"), withIntermediateDirectories: true)
        XCTAssertEqual(ModDependencies.missing(root: game), [], "Wine finds folders regardless of case")
        XCTAssertEqual(ModDependencies.launchedMod(arguments: "+restart 1 +game FHSW"), "FHSW")
        XCTAssertNil(ModDependencies.launchedMod(arguments: "+restart 1"))
    }

    func testReportParsingAndPlainExplanations() throws {
        let report = try XCTUnwrap(CrashReports.Report(Self.fhsw))
        XCTAssertEqual(report.module, "bf1942")
        XCTAssertEqual(report.address, 4)
        XCTAssertEqual(report.bits, "32-bit")
        XCTAssertEqual(report.commandLine, "BF1942.exe +game FHSW +restart 1 +goToInterface 8")
        let missing = ModDependencies.Missing(mod: "FHSW", needs: ["FH"])
        let withMod = CrashReports.explain(report, text: Self.fhsw, date: Date(), mods: [missing], arguments: "")
        XCTAssertEqual(withMod.missingMod, missing)
        XCTAssertEqual(withMod.title, "FHSW is missing a mod it needs")
        let plain = CrashReports.explain(report, text: Self.fhsw, date: Date(), mods: [], arguments: "")
        XCTAssertEqual(plain.title, "BF1942.exe tried to use something that isn't there")
        XCTAssertTrue(plain.evidence.hasPrefix("BF1942.exe, in bf1942"))

        let graphics = Self.fhsw.replacingOccurrences(of: "in bf1942 (+0x46314)", with: "in d3d9 (+0x1234)")
        XCTAssertEqual(CrashReports.explain(try XCTUnwrap(CrashReports.Report(graphics)), text: graphics, date: Date(), mods: [], arguments: "").title,
                       "BF1942.exe crashed in its graphics")
        let sound = Self.fhsw.replacingOccurrences(of: "in bf1942 (+0x46314)", with: "in dsound (+0x10)")
        XCTAssertEqual(CrashReports.explain(try XCTUnwrap(CrashReports.Report(sound)), text: sound, date: Date(), mods: [], arguments: "").title,
                       "BF1942.exe crashed in its sound")
        XCTAssertNil(CrashReports.Report("nothing crashed here"))
    }

    func testCaptureEditsOnlyDefaultDebuggersAndPreservesTheRest() throws {
        let contents = root.appendingPathComponent("Game.app/Contents")
        let prefix = contents.appendingPathComponent("SharedSupport/prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let system = prefix.appendingPathComponent("system.reg"), user = prefix.appendingPathComponent("user.reg")
        try #"""
        WINE REGISTRY Version 2
        ;; All keys relative to \\Machine

        [Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug] 1700000000
        #time=1d9
        "Auto"="1"
        "Debugger"="winedbg --auto %ld %ld"

        [Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug] 1700000000
        "Debugger"="C:\\tools\\mydebugger.exe %ld %ld"

        [Software\\Other] 1700000000
        "Keep"="me"

        """#.write(to: system, atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1700000000\n\"Version\"=\"win10\"\n".write(to: user, atomically: true, encoding: .utf8)

        XCTAssertTrue(CrashReports.ensureCapture(contents: contents))
        let sys = try String(contentsOf: system, encoding: .utf8)
        XCTAssertTrue(sys.contains(#""Debugger"="C:\\windows\\system32\\cmd.exe /c C:\\windows\\system32\\winedbg.exe --auto %ld %ld > C:\\nokcandu\\crash-report.txt 2>&1""#))
        XCTAssertTrue(sys.contains(#""Debugger"="C:\\tools\\mydebugger.exe %ld %ld""#), "a debugger chosen by hand stays")
        XCTAssertTrue(sys.contains("\"Keep\"=\"me\"") && sys.contains("\"Auto\"=\"1\"") && sys.contains("#time=1d9"))
        let usr = try String(contentsOf: user, encoding: .utf8)
        XCTAssertTrue(usr.contains("[Software\\\\Wine\\\\WineDbg]") && usr.contains("\"ShowCrashDialog\"=dword:00000000"))
        XCTAssertTrue(usr.contains("\"Version\"=\"win10\""))
        XCTAssertFalse(CrashReports.ensureCapture(contents: contents), "applying again changes nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/nokcandu").path))
    }
}
