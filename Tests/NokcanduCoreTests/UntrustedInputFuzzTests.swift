import XCTest
@testable import NokcanduCore

/// Random and broken data through everything that reads bytes or text Nokcandu doesn't control: controller reports
/// (a controller, or something posing as one), Steam's files, shared profiles and links. Nothing may crash (a bad
/// index or overflow traps in Swift) or hang; wrong input may only be refused.
final class UntrustedInputFuzzTests: XCTestCase {
    private struct RNG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 11 }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) } }

    /// Reports: random lengths (0…100) and contents, plus every report ID with random rest, plus truncations of each.
    private func reports(_ count: Int, seed: UInt64) -> [[UInt8]] {
        var r = RNG(s: seed), out: [[UInt8]] = []
        for i in 0..<count {
            let n = r.below(101)
            var b = (0..<n).map { _ in r.byte() }
            if !b.isEmpty, i % 3 == 0 { b[0] = UInt8(i % 256) }
            out.append(b)
            if n > 1 { out.append(Array(b.prefix(r.below(n)))) }
        }
        return out
    }

    func testTakenOverControllerReaders() {
        for kind in [TakeoverPad.ps4, .ps5, .xbox, .switchPro] {
            for bluetooth in [false, true] {
                var d = TakeoverPadDecoder(kind, bluetooth: bluetooth)
                _ = d.start()
                var t = 0.0
                for report in reports(3000, seed: 1) {
                    _ = d.decode(report); _ = d.repairs(after: report, at: t); t += 0.01
                    _ = d.rumble(low: Double(report.first ?? 0) / 100, high: .nan)
                }
                _ = d.rumble(low: .infinity, high: -5)
            }
        }
        for report in reports(3000, seed: 2) {
            _ = SwitchProPad.calibration(fromReply: report); _ = SwitchProPad.motionCalibration(fromReply: report)
            _ = XboxBluetoothPad.decode(report); _ = SwitchProPad.decode(report)
        }
    }

    func testOtherControllerReaders() {
        var seen = Set<String>()
        for (v, p) in ReportPadDriver.matching {
            guard let driver = ReportPadDriver.find(vendor: v, product: p), seen.insert(String(describing: driver)).inserted else { continue }
            var d = ReportPadDecoder(driver)
            _ = d.start()
            for report in reports(1500, seed: UInt64(v * 65536 + p)) { _ = d.decode(report); _ = d.takeOutputs() }
        }
        for report in reports(2000, seed: 3) {
            for product in Switch2Controller.products { _ = Switch2Controller.decode(report, product: product, calibration: .init()) }
            _ = Switch2Controller.flashData(report)
            _ = SteamController2026.decode(report, counter: 1)
            _ = SteamControllerReport.isInputReport(report)
        }
    }

    func testTextReaders() {
        var r = RNG(s: 9)
        let pieces = ["\"", "{", "}", "\n", "\\", "controller_mappings", "group", "binding", "preset", "key_press", "\"mode\"", "0", "-1",
                      "99999999999999999999", "layer", "nokpad", "[", "]", ":", ",", "\"name\"", "\"layers\"", "null", "é", "\u{0}", "%", "=", "/"]
        for _ in 0..<2000 {
            let text = (0..<r.below(60)).map { _ in pieces[r.below(pieces.count)] }.joined()
            _ = try? SteamInputImport.profile(fromVDF: text, fallbackName: "x")
            _ = try? PadProfiles.parseShared(text)
            _ = SteamInputSupport.readsItself(configVDF: text)
            _ = try? VDF.parse(text)
            _ = HeldOutputsJournal.read(Data(text.utf8))
            if let u = URL(string: "nokcandu://pad?p=" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) { _ = PadProfileLink.text(u) }
        }
        // Deeply nested and very large input is refused without hanging or blowing the stack.
        _ = try? SteamInputImport.profile(fromVDF: String(repeating: "\"a\" {", count: 20000), fallbackName: "x")
        XCTAssertThrowsError(try VDF.parse(String(repeating: "\"a\" {", count: 20000)))
        _ = try? PadProfiles.parseShared(String(repeating: "[", count: 20000))
    }
}
