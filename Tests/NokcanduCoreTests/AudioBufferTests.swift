import XCTest
@testable import NokcanduCore

final class AudioBufferCurrentTests: XCTestCase {
    func mov(_ v: UInt32) -> [UInt8] { [0x48, 0xC7, 0x01] + withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func driver(_ def: UInt32, _ min: UInt32) -> Data { Data([0x90] + mov(def) + [0x90] + mov(min) + [0x90] + mov(def) + mov(min)) }
    func testCurrent() {
        let o = driver(100_000, 50_000)
        XCTAssertEqual(AudioBuffer.current(driver: o, original: nil), 10)
        XCTAssertEqual(AudioBuffer.current(driver: o, original: o), 10)
        XCTAssertEqual(AudioBuffer.current(driver: driver(200_000, 100_000), original: o), 20)
        XCTAssertEqual(AudioBuffer.current(driver: driver(400_000, 200_000), original: o), 40)
    }

    func testMicrophoneFix() throws {
        let lookup: [UInt8] = [0x48, 0xB8, 0x75, 0x6F, 0x75, 0x61, 0x20, 0x66, 0x65, 0x64]
        let o = Data([UInt8](driver(100_000, 50_000)) + lookup + [0xC3])
        let a = try AudioBuffer.adjusted(o, ms: 10)
        XCTAssertTrue(AudioBuffer.offsets(of: lookup, in: [UInt8](a)).isEmpty)
        XCTAssertEqual(AudioBuffer.offsets(of: AudioBuffer.halLookup, in: [UInt8](a)).count, 1)
        XCTAssertEqual(AudioBuffer.current(driver: try AudioBuffer.adjusted(o, ms: 40), original: o), 40)
    }

    func testDriverStatus() throws {
        let lookup: [UInt8] = [0x48, 0xB8, 0x75, 0x6F, 0x75, 0x61, 0x20, 0x66, 0x65, 0x64]
        let o = Data([UInt8](driver(100_000, 50_000)) + lookup)
        XCTAssertEqual(AudioBuffer.status(driver: o), .needsFix)
        XCTAssertEqual(AudioBuffer.status(driver: try AudioBuffer.adjusted(o, ms: 20)), .fixed)
        XCTAssertEqual(AudioBuffer.status(driver: driver(100_000, 50_000)), .unrecognized)
    }
}
