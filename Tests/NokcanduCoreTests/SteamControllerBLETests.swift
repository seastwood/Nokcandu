import XCTest
@testable import NokcanduCore

/// Bluetooth packets built to the format in Valve's SDL driver (SDL_hidapi_steam.c): no controller was at hand.
final class SteamControllerBLETests: XCTestCase {
    /// A state packet's payload split into report-3 segments, as the controller sends it.
    private func segments(_ packet: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var i = 0
        repeat {
            var s = [UInt8](repeating: 0, count: 20)
            s[0] = 3
            let piece = packet[min(i, packet.count)..<min(packet.count, i + 18)]
            s.replaceSubrange(2..<(2 + piece.count), with: piece)
            i += 18
            s[1] = 0x80 | UInt8(result.count) | (i >= packet.count ? 0x40 : 0)
            result.append(s)
        } while i < packet.count
        return result
    }
    private func le(_ v: Int16) -> [UInt8] { [UInt8(UInt16(bitPattern: v) & 255), UInt8(UInt16(bitPattern: v) >> 8)] }

    func testCommandsSplitIntoReport3Segments() {
        let query = SteamControllerMode.query          // 0x89, 15, five tags: 17 bytes
        let one = SteamControllerBLE.segments(query)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].count, 20)
        XCTAssertEqual(Array(one[0].prefix(4)), [3, 0xC0, 0x89, 15])
        XCTAssertEqual(Array(one[0][2..<19]), Array(query.prefix(17)))

        var long = [UInt8](repeating: 0, count: 64); long[0] = 0x87; long[1] = 30
        for i in 2..<32 { long[i] = UInt8(i) }
        let two = SteamControllerBLE.segments(long)     // 32 bytes: 18 + 14
        XCTAssertEqual(two.map { $0[1] }, [0x80, 0xC1])
        XCTAssertEqual(Array(two[1][2..<16]), Array(long[18..<32]))
        XCTAssertEqual(SteamControllerBLE.segments(SteamControllerMode.clearDigitalMappings).first.map { Array($0.prefix(4)) }, [3, 0xC0, 0x81, 0])
    }

    func testRepliesJoinAndTheDoubledReportNumberIsSkipped() {
        var reply = [UInt8](repeating: 0, count: 32); reply[0] = 0x89; reply[1] = 15
        let parts = segments(reply)
        var a = SteamControllerBLE.Assembler()
        XCTAssertNil(a.add([3] + parts[0]))             // macOS: the report number twice
        XCTAssertEqual(a.add(parts[1]), Array(reply) + [UInt8](repeating: 0, count: 4))
        // A missing segment drops that packet only; empty segments and other reports are ignored.
        XCTAssertNil(a.add(parts[1]))
        XCTAssertNil(a.add([3, 0x00] + [UInt8](repeating: 0, count: 18)))
        XCTAssertNil(a.add([1] + [UInt8](repeating: 0, count: 19)))
        XCTAssertNil(a.add(parts[0])); XCTAssertNotNil(a.add(parts[1]))
    }

    func testStateChunksBecomeTheSameStateAsTheCable() {
        // Buttons A (bit 7) and right finger down (bit 20); left trigger 128; stick, right pad and gyro.
        var packet: [UInt8] = [0x04 | 0x10 | 0x20 | 0x80, 0x02 | 0x08]
        packet += [0x80, 0x00, 0x10]                    // chunk 1: buttons bytes 0–2
        packet += [128, 0]                              // chunk 2: triggers
        packet += le(16384) + le(-16384)                // left stick
        packet += le(1000) + le(-2000)                  // right pad
        packet += le(100) + le(-200) + le(300)          // gyro
        var stream = SteamControllerStream()
        var state: SteamControllerReport.State?
        for s in segments(packet) { state = stream.acceptBluetooth(s, at: 1) ?? state }
        let st = try! XCTUnwrap(state)
        XCTAssertEqual(st.buttons, [.a])
        XCTAssertTrue(st.rightTouch); XCTAssertFalse(st.leftTouch)
        XCTAssertEqual(st.leftTrigger, 128.0 / 255, accuracy: 1e-6)
        XCTAssertEqual(st.stick.x, 16384.0 / 32767, accuracy: 1e-6)
        XCTAssertEqual(st.rightPad.y, -2000.0 / 32767, accuracy: 1e-6)
        XCTAssertEqual(st.gyro[2], Float(300) * Float(2000.0 / 32768.0 * Double.pi / 180), accuracy: 1e-6)

        // The next packet carries only the right pad: the buttons, trigger and stick are kept.
        var next: [UInt8] = [0x04, 0x02]
        next += le(3000) + le(0)
        let after = try! XCTUnwrap(segments(next).compactMap { stream.acceptBluetooth($0, at: 1.01) }.last)
        XCTAssertEqual(after.buttons, [.a])
        XCTAssertEqual(after.stick, st.stick)
        XCTAssertEqual(after.rightPad.x, 3000.0 / 32767, accuracy: 1e-6)
        XCTAssertGreaterThan(after.counter, st.counter)
    }

    func testLeftPadAndStickAreSeparateOverBluetooth() {
        // Left finger down (bit 19): the left pad comes in its own chunk, the stick in another.
        var packet: [UInt8] = [0x04 | 0x10 | 0x80, 0x01]
        packet += [0x00, 0x00, 0x08]
        packet += le(5000) + le(0)                      // stick
        packet += le(-8000) + le(8000)                  // left pad
        var d = SteamControllerBLE.Decoder()
        let st = try! XCTUnwrap(d.decode(packet))
        XCTAssertTrue(st.leftTouch)
        XCTAssertEqual(st.stick.x, 5000.0 / 32767, accuracy: 1e-6)
        XCTAssertEqual(st.leftPad.x, -8000.0 / 32767, accuracy: 1e-6)
        // Finger lifted: the pad reads as centred.
        let lifted = try! XCTUnwrap(d.decode([0x04 | 0x10, 0x00, 0, 0, 0]))
        XCTAssertFalse(lifted.leftTouch)
        XCTAssertEqual(lifted.leftPad, SteamControllerReport.Point())
        // Status packets (type 5) aren't state; a cut-short packet is refused.
        XCTAssertNil(d.decode([0x05, 0x00]))
        XCTAssertNil(d.decode([0x04 | 0x80, 0x00, 1, 2]))
    }
}
