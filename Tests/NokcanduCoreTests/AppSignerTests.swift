import XCTest
@testable import NokcanduCore

/// The updater installs only an app signed by the signer of the one that is running.
final class AppSignerTests: XCTestCase {
    func testVerdicts() {
        let a = Data([1, 2, 3]), b = Data([4, 5, 6])
        XCTAssertEqual(AppSigner.verdict(current: a, update: a), .sameSigner)
        XCTAssertEqual(AppSigner.verdict(current: a, update: b), .differentSigner)
        XCTAssertEqual(AppSigner.verdict(current: a, update: nil), .unsigned, "an ad-hoc or unsigned update never replaces a signed app")
        XCTAssertEqual(AppSigner.verdict(current: nil, update: b), .developmentBuild, "a development build has no signer to compare with")
    }

    func testCertificatesOfRealApps() throws {
        let fm = FileManager.default
        // Two of Apple's own apps share a signer.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app"), clock = URL(fileURLWithPath: "/System/Applications/Clock.app")
        try XCTSkipUnless(fm.fileExists(atPath: calculator.path) && fm.fileExists(atPath: clock.path))
        let apple = try XCTUnwrap(AppSigner.certificate(of: calculator))
        XCTAssertEqual(AppSigner.certificate(of: clock), apple)
        XCTAssertNoThrow(try AppSigner.check(update: clock, current: calculator))
        // An ad-hoc signed app names no signer, and can't replace a signed one.
        let folder = fm.temporaryDirectory.appendingPathComponent("nok-signer-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("Fake.app"), macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fake"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>test.nokcandu.fake</string></dict></plist>".utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let signed = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60)
        try XCTSkipUnless(signed.ok)
        XCTAssertNil(AppSigner.certificate(of: app))
        XCTAssertThrowsError(try AppSigner.check(update: app, current: calculator))
        XCTAssertNoThrow(try AppSigner.check(update: calculator, current: app), "a development build still updates")
    }
}
