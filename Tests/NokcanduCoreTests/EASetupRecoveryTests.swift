import XCTest
@testable import NokcanduCore

final class EASetupRecoveryTests: XCTestCase {
    let manifest = #"""
    <game manifestVersion="3.0"><metadata><localeInfo locale="en_US"/><localeInfo locale="fr_FR"/></metadata>
    <executable><filePath>/__Installer/touchup.exe</filePath><parameters>install -locale {locale} -installPath "{installLocation}" -autologging</parameters></executable></game>
    """#
    func fixture() throws -> (InstalledGame, URL) {
        var host = try ProfileCompletenessTests().fixture()
        var config = try XCTUnwrap(host.custom); config.exe = EAAppInstaller.program
        host.custom = config
        let wine = host.support.appendingPathComponent("wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent())
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let folder = host.prefix.appendingPathComponent("drive_c/EA Games/A Game's Folder")
        let installer = folder.appendingPathComponent("__Installer")
        try NokPaths.ensure(installer)
        try OpenUASettingsTests().pe().write(to: installer.appendingPathComponent("Touchup.exe"))
        try Data("original setup data".utf8).write(to: installer.appendingPathComponent("Touchup.dat"))
        try manifest.write(to: installer.appendingPathComponent("installerdata.xml"), atomically: true, encoding: .utf8)
        return (host, folder)
    }
    func testPlanPreservesFolderAndUsesFixedOriginalInstallerArguments() throws {
        let (host, folder) = try fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL) }
        let p = try EASetupRecovery.plan(folder: folder, host: host, preferredLocale: "fr_FR")
        XCTAssertEqual(p.locale, "fr_FR")
        XCTAssertEqual(p.windowsFolder, #"C:\EA Games\A Game's Folder"#)
        XCTAssertEqual(Array(p.arguments.dropFirst()), ["install", "-locale", "fr_FR", "-installPath", p.windowsFolder, "-autologging"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p.arguments[0])),
                       try Data(contentsOf: folder.appendingPathComponent("__Installer/Touchup.exe")))
        XCTAssertEqual(try EASetupRecovery.manifestLocale(Data(manifest.utf8), preferred: "de_DE"), "en_US")
        try EASetupRecovery.verifyUnchanged(p)
        let installer = folder.appendingPathComponent("__Installer")
        try FileManager.default.moveItem(at: installer.appendingPathComponent("Touchup.exe"), to: installer.appendingPathComponent("touchup.exe"))
        XCTAssertNoThrow(try EASetupRecovery.plan(folder: folder, host: host))
        try Data("updated during download".utf8).write(to: folder.appendingPathComponent("__Installer/Touchup.dat"))
        XCTAssertThrowsError(try EASetupRecovery.verifyUnchanged(p))
    }
    func testRejectsUnrecognizedCommandsMissingPackagesAndEscapingLinks() throws {
        let fm = FileManager.default, (host, folder) = try fixture()
        defer { try? fm.removeItem(at: host.appURL) }
        for changed in [manifest.replacingOccurrences(of: "touchup.exe", with: "../../other.exe"),
                        manifest.replacingOccurrences(of: " -autologging", with: " & unwanted.exe"),
                        manifest.replacingOccurrences(of: "</game>", with: "<executable><filePath>/__Installer/touchup.exe</filePath></executable></game>")] {
            XCTAssertThrowsError(try EASetupRecovery.manifestLocale(Data(changed.utf8), preferred: "en_US"))
        }
        let exe = folder.appendingPathComponent("__Installer/Touchup.exe"), elsewhere = host.prefix.appendingPathComponent("outside.exe")
        try fm.moveItem(at: exe, to: elsewhere)
        try fm.createSymbolicLink(at: exe, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try EASetupRecovery.plan(folder: folder, host: host))
        try fm.removeItem(at: exe)
        XCTAssertThrowsError(try EASetupRecovery.plan(folder: folder, host: host))
        var other = host; other.custom?.exe = #"C:\Games\Other.exe"#
        XCTAssertThrowsError(try EASetupRecovery.plan(folder: folder, host: other))
    }
    func testExternalDriveMappingAndUnmappedFolder() throws {
        let fm = FileManager.default, (host, _) = try fixture()
        let external = fm.temporaryDirectory.appendingPathComponent("external-ea-" + UUID().uuidString)
        defer { try? fm.removeItem(at: host.appURL); try? fm.removeItem(at: external) }
        try NokPaths.ensure(external)
        XCTAssertThrowsError(try EASetupRecovery.windowsFolder(external, host: host))
        try Drives.add("E", to: external, for: host)
        let folder = external.appendingPathComponent("EA Games/Test")
        XCTAssertEqual(try EASetupRecovery.windowsFolder(folder, host: host), #"E:\EA Games\Test"#)
        try fm.createSymbolicLink(atPath: host.prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        XCTAssertEqual(try EASetupRecovery.windowsFolder(folder, host: host), "Z:" + folder.path.replacingOccurrences(of: "/", with: "\\"))
    }
    func testSetupFallbackIsProcessLocalAndKeepsOtherDLLRules() {
        let original = ["KEEP": "yes", "WINEDLLOVERRIDES": "gameux=n;d3d8,d3d9=b;dsound=n,b"]
        let env = EASetupRecovery.installerEnvironment(original)
        let rules = CompatibilityFixes.overrides(env["WINEDLLOVERRIDES"])
        XCTAssertEqual(rules["gameux"], "")
        XCTAssertEqual(rules["d3d8"], "b"); XCTAssertEqual(rules["d3d9"], "b")
        XCTAssertEqual(rules["dsound"], "n,b"); XCTAssertEqual(env["KEEP"], "yes")
        XCTAssertEqual(original["WINEDLLOVERRIDES"], "gameux=n;d3d8,d3d9=b;dsound=n,b")
    }

    func testOriginalEASetupE2E() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let app = env["NOKCANDU_EA_TEST_HOST"], let folder = env["NOKCANDU_EA_TEST_GAME"] else {
            throw XCTSkip("Requires an authorized EA game download and EA host")
        }
        let host = try XCTUnwrap(GameLibrary.inspect(URL(fileURLWithPath: app)))
        let target = URL(fileURLWithPath: folder)
        let plan = try EASetupRecovery.plan(folder: target, host: host, preferredLocale: "en_US")
        let log = try await EASetupRecovery.finish(plan, host: host)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Exit code: 0"))
        XCTAssertTrue(PCLaunchers.installedGames(.ea, host: host).contains { game in
            BattleNet.unixPath(game.installLocation, prefix: host.prefix)?.resolvingSymlinksInPath().standardizedFileURL == target.resolvingSymlinksInPath().standardizedFileURL
        })
    }

}
