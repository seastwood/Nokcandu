import XCTest
import CryptoKit
@testable import NokcanduCore

final class EAInstallerTests: XCTestCase {
    let xml = """
    <BurnManifest xmlns="http://schemas.microsoft.com/wix/2008/Burn">
    <Variable Id="CLIENT_VERSION" Value="13.813.1.6327"/>
    <Payload Packaging="external" FilePath="EAapp-13.813.1.6327.msi" FileSize="252137472" Hash="8296BC7250D7F2326C9284DBE35CAAEC84A91371" DownloadUrl="https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAapp-13.813.1.6327.msi"/>
    <Registration ProviderKey="{250aff32-1fed-43e8-aed3-72a816a7d007}" ExecutableName="EAappInstaller.exe"/>
    </BurnManifest>
    """
    func testReadsVersionedOfficialPackageAndRejectsUnexpectedMetadata() throws {
        let p = try EAAppInstaller.package(from: Data(xml.utf8))
        XCTAssertEqual(p.version, "13.813.1.6327")
        XCTAssertEqual(p.sha1, "8296bc7250d7f2326c9284dbe35caaec84a91371")
        for pair in [("https://origin-a.akamaihd.net", "https://example.com"),
                     ("EAapp-13.813.1.6327.msi", "../EAapp-13.813.1.6327.msi"),
                     ("13.813.1.6327\"/>", "13.813.1&evil\"/>"),
                     ("8296BC7250D7F2326C9284DBE35CAAEC84A91371", "bad"),
                     ("{250aff32-1fed-43e8-aed3-72a816a7d007}", "../../outside")] {
            XCTAssertThrowsError(try EAAppInstaller.package(from: Data(xml.replacingOccurrences(of: pair.0, with: pair.1).utf8)))
        }
    }
    func testPackageVerificationRejectsChangedAndTruncatedDownloads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data(repeating: 0x31, count: 1_000_000)
        try data.write(to: file)
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let p = EAAppInstaller.Package(name: "EAapp-test.msi", url: URL(string: "https://origin-a.akamaihd.net/")!,
                                       sha1: hash, size: Int64(data.count), version: "1.0", provider: "test")
        XCTAssertTrue(EAAppInstaller.verifies(file, package: p))
        var changed = data; changed[0] = 0x32
        try changed.write(to: file)
        XCTAssertFalse(EAAppInstaller.verifies(file, package: p))
        try Data(data.prefix(100)).write(to: file)
        XCTAssertFalse(EAAppInstaller.verifies(file, package: p))
    }
    func testSharedMSIPropertiesQuoteOnlyTheValueAndRejectCommandExpansion() throws {
        let command = try WindowsMSI.command(package: #"C:\setup.msi"#, log: #"C:\setup.log"#,
            properties: ["INSTALL_ROOT": #"C:\Program Files\Electronic Arts\EA Desktop"#, "EAX_DISABLE_SYMLINKS": "1"])
        XCTAssertTrue(command.contains(#"INSTALL_ROOT="C:\Program Files\Electronic Arts\EA Desktop""#))
        XCTAssertTrue(command.contains(#"EAX_DISABLE_SYMLINKS="1""#))
        XCTAssertTrue(command.hasSuffix("exit /b %errorlevel%\r\n"))
        for value in ["%TEMP%", "evil&command", "test\"value", "bad\nvalue", "!VAR!"] {
            XCTAssertThrowsError(try WindowsMSI.command(package: #"C:\setup.msi"#, log: #"C:\log"#, properties: ["X": value]))
        }
        XCTAssertThrowsError(try WindowsMSI.command(package: "setup.msi", log: "log", properties: ["X&Y": "value"]))
    }
}
