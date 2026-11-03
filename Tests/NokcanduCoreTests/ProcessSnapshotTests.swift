import XCTest
@testable import NokcanduCore

final class ProcessSnapshotTests: XCTestCase {
    func testFailureRetainsRowsButNeverReportsReliableAbsence() {
        let cache = ProcessSnapshotCache(), now = Date()
        XCTAssertTrue(cache.read(now: now) { [(42, "wine")] }.reliable)
        let failed = cache.read(now: now.addingTimeInterval(2)) { throw NokError("scan failed") }
        XCTAssertFalse(failed.reliable); XCTAssertEqual(failed.rows.first?.0, 42)
        var loaded = false
        XCTAssertFalse(cache.read(now: now.addingTimeInterval(3)) { loaded = true; return [] }.reliable)
        XCTAssertFalse(loaded)
        let recovered = cache.read(now: now.addingTimeInterval(6)) { [] }
        XCTAssertTrue(recovered.reliable); XCTAssertTrue(recovered.rows.isEmpty)
    }
    func testOverlappingReaderDoesNotWaitBehindSlowScan() {
        let cache = ProcessSnapshotCache(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "scan finished")
        _ = cache.read(now: Date().addingTimeInterval(-10)) { [(42, "wine")] }
        DispatchQueue.global().async {
            _ = cache.read { entered.signal(); _ = release.wait(timeout: .now() + 5); return [] }
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        let start = Date(), value = cache.read { XCTFail("Must not start a second scan"); return [] }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertFalse(value.reliable); XCTAssertEqual(value.rows.first?.0, 42)
        release.signal(); wait(for: [finished], timeout: 3)
    }
    func testActivationRequiresMatchingLiveBirthAndBuild() {
        let record = HelperActivation.Record(pid: 42, startSeconds: 100, startMicros: 2, build: "new", role: "server")
        func state(_ records: [HelperActivation.Record], installed: String? = "new", reliable: Bool = true, birth: (UInt64, UInt64)? = (100, 2)) -> HelperActivation {
            HelperActivation.assess(expected: "new", installed: installed, processes: [42], records: records, reliable: reliable) { _ in birth }
        }
        XCTAssertEqual(state([record]), .current)
        XCTAssertEqual(state([]), .restartRequired)
        XCTAssertEqual(state([record], birth: (101, 2)), .restartRequired)
        XCTAssertEqual(state([record], birth: nil), .restartRequired)
        XCTAssertEqual(state([record], installed: "old"), .updateRequired)
        XCTAssertEqual(state([record], reliable: false), .unknown)
        var old = record; old.build = "old"
        XCTAssertEqual(state([old]), .restartRequired)
        XCTAssertEqual(HelperActivation.assess(expected: "new", installed: "new", processes: [], records: [], reliable: true) { _ in nil }, .ready)
    }
}

extension ProcessSnapshotTests {
    func testLoadedHelperRecordsKernelBirthAndEmbeddedBuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loaded-helper-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Fixture.app/Contents/SharedSupport/nokcandu")
        try NokPaths.ensure(folder)
        let library = folder.appendingPathComponent(RawMouse.dylibName)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/rawmouse/helper-state.c")
        let compiled = try Shell.run("/usr/bin/xcrun", ["clang", "-dynamiclib", "-Wall", "-Wextra", "-Werror", "-DNOKCANDU_HELPER_BUILD=\"fixture-build\"", source.path, "-o", library.path], timeout: 30)
        XCTAssertTrue(compiled.ok, compiled.combined)
        let main = root.appendingPathComponent("main.c"), binary = root.appendingPathComponent("probe")
        try Data("""
        #include <dlfcn.h>
        #include <libproc.h>
        #include <sys/proc_info.h>
        #include <unistd.h>
        #include <stdio.h>
        int main(int argc,char **argv){if(argc!=2||!dlopen(argv[1],RTLD_NOW))return 1;struct proc_bsdinfo p;if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&p,sizeof(p))!=sizeof(p))return 2;printf("%d %llu %llu",getpid(),(unsigned long long)p.pbi_start_tvsec,(unsigned long long)p.pbi_start_tvusec);return 0;}
        """.utf8).write(to: main)
        let built = try Shell.run("/usr/bin/xcrun", ["clang", main.path, "-o", binary.path], timeout: 30)
        XCTAssertTrue(built.ok, built.combined)
        let result = try Shell.run(binary.path, [library.path], timeout: 10)
        XCTAssertTrue(result.ok, result.combined)
        let fields = result.stdout.split(separator: " ")
        XCTAssertEqual(fields.count, 3)
        guard fields.count == 3 else { return }
        let record = try JSONDecoder().decode(HelperActivation.Record.self, from: Data(contentsOf: folder.appendingPathComponent("loaded-helpers/\(fields[0]).json")))
        XCTAssertEqual(record.pid, Int32(fields[0])); XCTAssertEqual(record.startSeconds, UInt64(fields[1]))
        XCTAssertEqual(record.startMicros, UInt64(fields[2])); XCTAssertEqual(record.build, "fixture-build")
        XCTAssertEqual(record.role, "program")
    }
}
