import XCTest
@testable import NokcanduCore

final class ProcessOutputTests: XCTestCase {
    func testExitedParentDoesNotWaitForDescendantOutputEOF() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: marker)
        }
        let script = "sleep 20 &\necho $! > " + CustomGames.shellQuote(marker.path) + "\necho finished\n"
        let started = Date()
        let result = try await Shell.runAsync("/bin/sh", ["-c", script], timeout: 3)
        XCTAssertTrue(result.ok); XCTAssertTrue(result.stdout.contains("finished"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        let sync = try Shell.run("/bin/sh", ["-c", script], timeout: 3)
        XCTAssertTrue(sync.ok); XCTAssertTrue(sync.stdout.contains("finished"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    func testLargeOutputOnBothPipesIsDrainedAndBounded() async throws {
        let script = "i=0; while [ $i -lt 15000 ]; do echo 'stdout abcdefghijklmnopqrstuvwxyz'; echo 'stderr abcdefghijklmnopqrstuvwxyz' >&2; i=$((i+1)); done; echo END; echo ERR_END >&2"
        let r = try await Shell.runAsync("/bin/sh", ["-c", script], timeout: 10)
        XCTAssertTrue(r.ok); XCTAssertTrue(r.stdout.hasSuffix("END\n")); XCTAssertTrue(r.stderr.hasSuffix("ERR_END\n"))
        XCTAssertLessThanOrEqual(r.stdout.utf8.count, 256 * 1024)
        XCTAssertLessThanOrEqual(r.stderr.utf8.count, 256 * 1024)
    }
    func testTimeoutAndCancellationReturnPromptly() async throws {
        let started = Date()
        do { _ = try await Shell.runAsync("/bin/sleep", ["20"], timeout: 0.1); XCTFail("Must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Timed out")) }
        let task = Task { try await Shell.runAsync("/bin/sleep", ["20"]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError {} catch { XCTFail("\\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
