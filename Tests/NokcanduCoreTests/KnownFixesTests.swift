import XCTest
@testable import NokcanduCore

final class KnownFixesTests: XCTestCase {
    func testParse() {
        let py = #"""
        """ Game fix for Something
        """
        # pylint: disable=C0103
        from protonfixes import util
        from protonfixes.util import OverrideOrder

        def main() -> None:
            """Needs xact and d3dx9, skips intro"""
            util.protontricks('xact')
            util.protontricks("d3dx9_43")
            util.append_argument('-nointro')
            util.set_environment('DXVK_ASYNC', '1')
            util.winedll_override('dinput8', OverrideOrder.NATIVE_BUILTIN)
            util.disable_esync()
            util.regedit_add(
                'HKCU\\Software\\Foo',
                'Bar',
                'REG_DWORD',
                '1',
            )
        """#
        let f = KnownFixes.parse(py, source: URL(string: "https://example.com")!)
        XCTAssertEqual(f.summary, "Needs xact and d3dx9, skips intro")
        XCTAssertEqual(f.verbs, ["xact", "d3dx9_43"])
        XCTAssertEqual(f.arguments, ["-nointro"])
        XCTAssertEqual(f.environment, ["DXVK_ASYNC": "1"])
        XCTAssertEqual(f.dllOverrides, ["dinput8": "n,b"])
        XCTAssertEqual(f.notApplied.count, 1)
        XCTAssertTrue(f.notApplied[0].hasPrefix("Registry setting"))
    }

    func testCSV() {
        XCTAssertEqual(KnownFixes.csvFields(#"Foo,egs,"a,b",umu-1"#), ["Foo", "egs", "a,b", "umu-1"])
    }
}
