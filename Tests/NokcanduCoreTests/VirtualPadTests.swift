import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class VirtualPadTests: XCTestCase {
    private func descriptor(_ kind: Int32) -> [UInt8] {
        var n = 0
        let p = vp_descriptor(kind, &n)!
        return Array(UnsafeBufferPointer(start: p, count: n))
    }
    /// The C array named `name` in a Wine controller-driver header, as bytes.
    private func wineArray(_ file: String, _ name: String) throws -> [UInt8] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Engine/controller-hid/\(file)"), encoding: .utf8)
        let start = text.range(of: name)!.upperBound
        let body = text[start...].split(separator: "{", maxSplits: 1)[1].split(separator: "}", maxSplits: 1)[0]
        return body.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "0x", with: ""), radix: 16) }
    }

    func testDescriptorsMatchTheWineDriver() throws {
        // The emulation in Wine builds this same core in; the real-Pro correction (patch 0001) keeps its own copy.
        XCTAssertEqual(descriptor(Int32(VP_SWITCH_PRO)), try wineArray("pro-hid-descriptor.h", "nok_pro_full_state[] ="))
        XCTAssertEqual(descriptor(Int32(VP_DS4)).count, 203, "DualShock 4 descriptor (the one verified in Wine)")
        XCTAssertGreaterThan(descriptor(Int32(VP_XBOX)).count, 100)
    }

    func testIdentities() {
        XCTAssertEqual(vp_vendor(Int32(VP_XBOX)), 0x045e); XCTAssertEqual(vp_product(Int32(VP_XBOX)), 0x0b13)
        XCTAssertEqual(vp_product(Int32(VP_DS4)), 0x05c4); XCTAssertEqual(vp_product(Int32(VP_SWITCH_PRO)), 0x2009)
        XCTAssertEqual(String(cString: vp_name(Int32(VP_SWITCH_PRO))), "Pro Controller")
    }

    private func state(buttons: [Int32] = [], axes: [Int: Int16] = [:]) -> vp_state {
        var s = vp_state()
        for b in buttons { s.buttons |= 1 << UInt32(b) }
        withUnsafeMutableBytes(of: &s.axes) { raw in
            let a = raw.bindMemory(to: Int16.self)
            for (i, v) in axes { a[i] = v }
        }
        s.accel.1 = 9.80665
        return s
    }

    private func input(_ kind: Int32, _ s: vp_state, device: inout vp_device) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        var st = s
        let n = vp_input_report(&device, &st, &out, 64)
        return Array(out.prefix(n))
    }

    func testDualShock4Report() {
        var d = vp_device(); vp_init(&d, Int32(VP_DS4), 0)
        let r = input(Int32(VP_DS4), state(buttons: [Int32(PE_A), Int32(PE_UP)], axes: [0: 32767, 5: 32767]), device: &d)
        XCTAssertEqual(r.count, 64); XCTAssertEqual(r[0], 1)
        XCTAssertEqual(r[1], 255, "left stick right")
        XCTAssertEqual(r[5] & 0x0f, 0, "hat up"); XCTAssertNotEqual(r[5] & 0x20, 0, "south is cross")
        XCTAssertEqual(r[9], 255, "R2"); XCTAssertNotEqual(r[6] & 0x08, 0)
        XCTAssertEqual(Int16(bitPattern: UInt16(r[21]) | UInt16(r[22]) << 8), 8192, "1 g on y")
        var f = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(vp_feature(&d, 0x02, &f, 64), 37)
        XCTAssertEqual(vp_feature(&d, 0x12, &f, 64), 16)
        XCTAssertEqual(vp_feature(&d, 0x81, &f, 64), 0)
        // Rumble and the light bar from output report 0x05.
        let out: [UInt8] = [0x05, 0x03, 0, 0, 0x40, 0xc0, 1, 2, 3]
        var st = state()
        vp_output(&d, &st, out, out.count, nil, nil)
        XCTAssertEqual(d.rumble_strong, 0xc0 * 257); XCTAssertEqual(d.rumble_weak, 0x40 * 257)
        XCTAssertTrue(d.light_changed); XCTAssertEqual(d.light.2, 3)
    }

    final class Replies { var reports: [[UInt8]] = [] }
    private func send(_ d: inout vp_device, _ bytes: [UInt8], _ replies: Replies) {
        var st = state()
        let ctx = Unmanaged.passUnretained(replies).toOpaque()
        vp_output(&d, &st, bytes, bytes.count, { ctx, p, n in
            Unmanaged<Replies>.fromOpaque(ctx!).takeUnretainedValue().reports.append(Array(UnsafeBufferPointer(start: p, count: n)))
        }, ctx)
    }

    func testSwitchProHandshakeAndSubcommands() {
        var d = vp_device(); vp_init(&d, Int32(VP_SWITCH_PRO), 1)
        let r = Replies()
        send(&d, [0x80, 0x01] + [UInt8](repeating: 0, count: 62), r)
        XCTAssertEqual(r.reports.last?[0], 0x81); XCTAssertEqual(r.reports.last?[3], 0x03, "Pro")
        XCTAssertEqual(r.reports.last?[9], 0x7c ^ 1, "its own address")
        send(&d, [0x80, 0x04] + [UInt8](repeating: 0, count: 62), r)
        XCTAssertEqual(r.reports.count, 1, "no reply to USB-only")
        send(&d, [0x01, 0, 0, 1, 0x40, 0x40, 0, 1, 0x40, 0x40, 0x10, 0x3d, 0x60, 0, 0, 0x12] + [UInt8](repeating: 0, count: 33), r)
        let spi = r.reports.last!
        XCTAssertEqual(spi[13], 0x90); XCTAssertEqual(spi[14], 0x10)
        XCTAssertEqual(Int(spi[23]) | Int(spi[24] & 0x0f) << 8, 2048, "left stick centre")
        let full = input(Int32(VP_SWITCH_PRO), state(buttons: [Int32(PE_A)], axes: [1: -32768]), device: &d)
        XCTAssertEqual(full[0], 0x30); XCTAssertNotEqual(full[3] & 0x04, 0, "south is B")
        let y = Int(full[7] >> 4) | Int(full[8]) << 4
        XCTAssertGreaterThan(y, 3800, "up")
    }

    func testXboxReport() {
        var d = vp_device(); vp_init(&d, Int32(VP_XBOX), 0)
        let r = input(Int32(VP_XBOX), state(buttons: [Int32(PE_A), Int32(PE_START), Int32(PE_RIGHT)], axes: [0: 32767, 4: 32767]), device: &d)
        XCTAssertEqual(r.count, 17); XCTAssertEqual(r[0], 1)
        XCTAssertEqual(UInt16(r[1]) | UInt16(r[2]) << 8, 65535, "left stick right")
        XCTAssertEqual(UInt16(r[9]) | UInt16(r[10]) << 8, 1023, "left trigger full")
        XCTAssertEqual(r[13], 3, "hat right")
        XCTAssertEqual((UInt16(r[14]) | UInt16(r[15]) << 8) & 0x0801, 0x0801, "A and Menu")
        let rumble: [UInt8] = [0x03, 0x0f, 0, 0, 100, 50, 0xff, 0, 0]
        var st = state()
        vp_output(&d, &st, rumble, rumble.count, nil, nil)
        XCTAssertEqual(d.rumble_strong, 65535); XCTAssertEqual(d.rumble_weak, 32767)
    }
}

final class PresentedControllerRoutingTests: XCTestCase {
    func testAPresentingProfileTakesTheSDLRouteEvenAsItself() throws {
        let contents = FileManager.default.temporaryDirectory.appendingPathComponent("present-\(UUID().uuidString)/Contents")
        let folder = contents.appendingPathComponent("SharedSupport/nokcandu")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        try "nokpad 1\n".write(to: folder.appendingPathComponent("pad-map"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Controllers.effective(.native, contents: contents), .native, "a profile without an identity leaves \"as itself\" alone")
        try "nokpad 1\npresent switchpro\n".write(to: folder.appendingPathComponent("pad-map"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Controllers.effective(.native, contents: contents), .xbox)
        XCTAssertEqual(Controllers.effective(.hidden, contents: contents), .hidden, "\"not at all\" still wins")
        try "1\n".write(to: folder.appendingPathComponent("pad-driver-off"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Controllers.effective(.native, contents: contents), .native, "the profile isn't running in the driver")
    }
}
