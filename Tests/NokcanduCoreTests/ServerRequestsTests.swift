import XCTest
@testable import NokcanduCore

final class ServerRequestsTests: XCTestCase {
    /// A fake executable: request names in a string area, then a table of chained-fixup pointers to them.
    func image(_ names: [String]) -> Data {
        var d = Data(count: 64)
        var offsets: [Int] = []
        d.append(0)
        for n in names { offsets.append(d.count); d.append(contentsOf: Array(n.utf8)); d.append(0) }
        while d.count % 8 != 0 { d.append(0) }
        for (i, o) in offsets.enumerated() {
            // DYLD_CHAINED_PTR_64_OFFSET: target in the low 36 bits, "next" in bits 51…62.
            var v = UInt64(o) | (i < offsets.count - 1 ? UInt64(1) << 51 : 0)
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
        }
        d.append(Data(count: 16))
        return d
    }

    func testFindsTheRequestTable() {
        var names = ["new_process", "get_new_process_info"]
        names += (0..<120).map { "request_\($0)" }
        names += ["flush_key", "flush_key_done", "set_queue_fd"]
        let t = WindowedPresentation.requestNames(inMachO: image(names))
        XCTAssertEqual(t, names)
    }

    func testNoTableInAnUnrelatedFile() {
        XCTAssertNil(WindowedPresentation.requestNames(inMachO: Data(repeating: 7, count: 4096)))
    }
}
