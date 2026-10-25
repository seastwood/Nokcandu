import XCTest
@testable import NokcanduCore

final class CoreTests: XCTestCase {
    var packageRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testLauncherTemplateIsKnownAndPatchRoundTrips() throws {
        let template = packageRoot.appendingPathComponent("Resources/generals-launcher")
        let text = try String(contentsOf: template, encoding: .utf8)
        XCTAssertNotNil(RecipeCatalog.zeroHour.knownLauncherHashes[try Hashing.sha256(file: template)])
        let patched = try XCTUnwrap(DisplayController.patchLauncher(text))
        XCTAssertTrue(patched.contains(DisplayController.patchMarker))
        XCTAssertNil(DisplayController.patchLauncher(patched), "must not patch twice")
        let restored = patched.replacingOccurrences(of: DisplayController.patchedLines.trimmingCharacters(in: .newlines),
                                                    with: DisplayController.originalLine)
        XCTAssertEqual(restored, text)
    }

    func testOptionsAndLauncherJSONEdits() {
        let ini = "AntiAliasing = 0\nResolution = 1470 956\nStaticGameLOD = Medium\n"
        let w = DisplayController.setResolution(in: ini, width: 1280, height: 800)
        XCTAssertEqual(DisplayController.resolution(in: w), "1280 800")
        XCTAssertTrue(w.contains("StaticGameLOD = Medium"))
        XCTAssertEqual(DisplayController.resolution(in: DisplayController.setResolution(in: "A = 1", width: 3, height: 4)), "3 4")

        let json = "{\n  \"prefer_experiemental_client\": true,\n  \"windowed\": false,\n  \"windowed_width\": 1280\n}"
        let on = DisplayController.setWindowed(in: json, true)!
        XCTAssertEqual(DisplayController.windowedFlag(in: on), true)
        XCTAssertTrue(on.contains("\"windowed_width\": 1280"))
        XCTAssertEqual(DisplayController.windowedFlag(in: DisplayController.setWindowed(in: on, false)!), false)
    }

    func testInstallScriptRegistry() throws {
        let vdf = #"""
        "InstallScript"
        {
            "Registry"
            {
                "HKEY_LOCAL_MACHINE_WOW64_32\\SOFTWARE\\Electronic Arts\\EA Games\\Command and Conquer Generals Zero Hour"
                {
                    "dword" { "english" { "MapPackVersion" "65536" "version" "65540" } "french" { "version" "1" } }
                    "string" { "english" { "InstallPath" "%INSTALLDIR%\\" "language" "english" } }
                }
            }
            "Run Process" { }
        }
        "kvsignatures" { "InstallScript" "abc" }
        """#
        let reg = try VDF.registryFile(fromInstallScript: try VDF.parse(vdf), installDir: #"C:\Games\Zero Hour"#)
        XCTAssertTrue(reg.contains(#"[HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Electronic Arts\EA Games\Command and Conquer Generals Zero Hour]"#))
        XCTAssertTrue(reg.contains(#""InstallPath"="C:\\Games\\Zero Hour\\""#))
        XCTAssertTrue(reg.contains(#""version"=dword:00010004"#))
        XCTAssertFalse(reg.contains("=dword:00000001"), "only the chosen language")
    }

    func testJournalRevertsAndRespectsOutsideChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try "original".write(to: a, atomically: true, encoding: .utf8)
        try "theirs".write(to: b, atomically: true, encoding: .utf8)

        let j = ChangeJournal(scope: "t", root: root)
        try j.write(Data("one".utf8), to: a, reason: "1")
        try j.write(Data("two".utf8), to: a, reason: "2")
        try j.write(Data("mine".utf8), to: b, reason: "b")
        try "edited by game".write(to: b, atomically: true, encoding: .utf8)   // outside change

        let reloaded = ChangeJournal(scope: "t", root: root)
        XCTAssertEqual(reloaded.entries.count, 3)
        let report = reloaded.revertAll()
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "edited by game")
        XCTAssertEqual(report.restored.count, 1)
        XCTAssertEqual(report.skipped.count, 1)
    }

    func testRecipesAreConsistent() {
        for r in RecipeCatalog.all {
            XCTAssertFalse(r.knownLauncherHashes.isEmpty)
            for (_, sha) in r.pinnedHashes { XCTAssertEqual(sha.count, 64) }
        }
        XCTAssertEqual(ZeroHourInstall.stages.map(\.info.id).count, Set(ZeroHourInstall.stages.map(\.info.id)).count)
    }
}
