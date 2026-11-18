import XCTest
@testable import NokcanduCore

final class StreamSessionActivityTests: XCTestCase {
    func testSessionProtectionDoesNotDependOnControllersAndStopsExactlyOnce() {
        var begins = 0, ends = 0
        let token = NSObject()
        var activity: StreamSessionActivity? = StreamSessionActivity(begin: { begins += 1; return token }, end: {
            XCTAssertTrue(($0 as AnyObject) === token); ends += 1
        })
        activity?.start(); activity?.start()
        XCTAssertEqual(begins, 1)
        activity?.stop(); activity?.stop(); activity = nil
        XCTAssertEqual(ends, 1)
        XCTAssertTrue(StreamSessionActivity.options.contains(.latencyCritical))
        XCTAssertTrue(StreamSessionActivity.options.contains(.userInitiated))
        XCTAssertTrue(StreamSessionActivity.options.contains(.idleDisplaySleepDisabled))
    }
    func testAbandonedOrFailedSessionReleasesItsActivity() {
        var ends = 0
        var activity: StreamSessionActivity? = StreamSessionActivity(begin: { NSObject() }, end: { _ in ends += 1 })
        activity?.start(); activity = nil
        XCTAssertEqual(ends, 1)
        let unused = StreamSessionActivity(begin: { XCTFail("No session started"); return NSObject() }, end: { _ in XCTFail("No activity to release") })
        unused.stop()
    }
}

final class StreamTelemetryTests: XCTestCase {
    func testIntervalsUnitsLossAndSeparatePipelineStages() throws {
        let t = StreamTelemetry(at: 10)
        t.receive(frame: 10, bytes: 125_000, hostLatencyTenthsMs: 20, assemblyMs: 1, queueMs: 0.2, at: 10)
        t.receive(frame: 12, bytes: 125_000, hostLatencyTenthsMs: 40, assemblyMs: 3, queueMs: 0.4, at: 10.5)
        t.decoded(milliseconds: 2); t.decoded(milliseconds: 3)
        t.enqueued(waitMs: 16); t.buffer(depth: 1); t.buffer(depth: 2)
        t.displayTick(at: 10); t.displayTick(at: 10.016); t.displayTick(at: 10.3)
        t.paced(dropped: 1); t.dropped()
        let s = t.roll(at: 11, networkMs: 5, variationMs: 1)
        XCTAssertEqual(s.receivedFPS, 2); XCTAssertEqual(s.decodedFPS, 2); XCTAssertEqual(s.shownFPS, 1)
        XCTAssertEqual(s.bitrateMbps, 2); XCTAssertEqual(s.peakBitrateMbps, 2)
        XCTAssertEqual(s.hostMinMs, 2); XCTAssertEqual(s.hostMs, 3); XCTAssertEqual(s.hostMaxMs, 4)
        XCTAssertEqual(s.decodeMinMs, 2); XCTAssertEqual(s.decodeMs, 2.5); XCTAssertEqual(s.decodeMaxMs, 3)
        XCTAssertEqual(s.presentationMs, 16); XCTAssertEqual(s.assemblyMs, 2)
        XCTAssertEqual(try XCTUnwrap(s.queueMs), 0.3, accuracy: 0.00001)
        XCTAssertEqual(s.bufferedFrames, 1.5); XCTAssertEqual(s.networkDropped, 1)
        XCTAssertEqual(try XCTUnwrap(s.networkDropPercent), 100.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(s.pacingDropPercent), 100.0 / 3, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(s.arrivalGapMaxMs), 500, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(s.displayGapMaxMs), 284, accuracy: 0.00001)
        XCTAssertEqual(s.networkMs, 5); XCTAssertEqual(s.networkVariationMs, 1)
        XCTAssertEqual(s.dropped, 1); XCTAssertEqual(s.pacedDrops, 1)
        let empty = t.roll(at: 12)
        XCTAssertNil(empty.hostMs); XCTAssertNil(empty.decodeMs); XCTAssertNil(empty.networkMs)
        XCTAssertEqual(empty.networkDropPercent, s.networkDropPercent)
        XCTAssertEqual(empty.pacingDropPercent, s.pacingDropPercent)
        XCTAssertEqual(empty.bitrateMbps, 0); XCTAssertEqual(empty.peakBitrateMbps, 2)
        XCTAssertEqual(empty.dropped, 1, "Lifetime totals survive interval resets")
    }
    func testFrameWrapAndRestartDoNotBecomeBillionsOfDroppedFrames() {
        let t = StreamTelemetry(at: 0)
        for (i, frame) in [UInt32.max - 1, .max, 0, 1].enumerated() {
            t.receive(frame: frame, bytes: 1, hostLatencyTenthsMs: 0, assemblyMs: nil, queueMs: nil, at: Double(i) / 10)
        }
        XCTAssertEqual(t.roll(at: 1).networkDropped, 0)
        let reset = StreamTelemetry(at: 0)
        for frame: UInt32 in [100, 50, 51, 51] {
            reset.receive(frame: frame, bytes: 1, hostLatencyTenthsMs: 0, assemblyMs: nil, queueMs: nil, at: 0)
        }
        XCTAssertEqual(reset.roll(at: 1).networkDropped, 0)
    }
    func testPacingAcrossSamplingBoundaryUsesTheSameLifetimeDenominator() {
        let t = StreamTelemetry(at: 0)
        t.receive(frame: 1, bytes: 1, hostLatencyTenthsMs: 0, assemblyMs: nil, queueMs: nil, at: 0.9)
        _ = t.roll(at: 1)
        t.decoded(milliseconds: 2); t.paced(dropped: 1)
        let later = t.roll(at: 2)
        XCTAssertEqual(later.pacingDropPercent, 100)
        XCTAssertEqual(later.networkDropPercent, 0)
    }
    func testDisplayCallbackPauseIsDistinctFromHealthyArrivalAndEnqueueCadence() throws {
        let t = StreamTelemetry(at: 0)
        for i in 0..<60 {
            let time = Double(i) / 60
            t.receive(frame: UInt32(i), bytes: 100, hostLatencyTenthsMs: 20, assemblyMs: 1, queueMs: 0, at: time)
            t.decoded(milliseconds: 3)
            t.enqueued(waitMs: 1, at: time + 0.004)
        }
        t.displayTick(at: 0); t.displayTick(at: 0.5)
        let s = t.roll(at: 1)
        XCTAssertEqual(try XCTUnwrap(s.displayGapMaxMs), 500, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(s.arrivalGapMaxMs), 1000.0 / 60, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(s.enqueueGapMaxMs), 1000.0 / 60, accuracy: 0.00001)
        XCTAssertEqual(s.presentationMaxMs, 1)
        XCTAssertEqual(s.decodeMaxMs, 3)
        XCTAssertEqual(s.networkDropped, 0)
    }
    func testMainQueueStallPreservesEnqueueGapAndMaximumWaitAcrossRolls() {
        let t = StreamTelemetry(at: 0)
        t.enqueued(waitMs: 1, at: 0.9)
        _ = t.roll(at: 1)
        t.enqueued(waitMs: 500, at: 1.4)
        t.enqueued(waitMs: 1, at: 1.416)
        let s = t.roll(at: 2)
        XCTAssertEqual(s.enqueueGapMaxMs ?? 0, 500, accuracy: 0.00001)
        XCTAssertEqual(s.presentationMaxMs, 500)
        XCTAssertEqual(s.presentationMs, 250.5)
    }
    func testLongSamplingGapUsesElapsedTimeAndPreservesStall() throws {
        let t = StreamTelemetry(at: 0)
        t.receive(frame: 1, bytes: 1_000_000, hostLatencyTenthsMs: 0, assemblyMs: nil, queueMs: nil, at: 0)
        t.displayTick(at: 0); t.displayTick(at: 2)
        let s = t.roll(at: 2)
        XCTAssertEqual(s.bitrateMbps, 4); XCTAssertEqual(s.receivedFPS, 0.5)
        XCTAssertEqual(s.displayGapMaxMs, 2000)
        XCTAssertEqual(t.roll(at: 2).duration, 0, "Overlay switches must not add duplicate samples")
    }
    func testGraphHistoryIsBoundedAndRejectsDuplicateOrInvalidSamples() {
        var h = StreamTelemetryHistory()
        for i in 1...500 { var s = StreamTelemetry.Sample(); s.time = Double(i); s.duration = 1; h.append(s) }
        XCTAssertEqual(h.samples.count, 120); XCTAssertEqual(h.samples.first?.time, 381)
        var bad = StreamTelemetry.Sample(); bad.time = .nan; bad.duration = 1; h.append(bad)
        h.append(h.samples.last!); h.append(StreamTelemetry.Sample())
        XCTAssertEqual(h.samples.count, 120); XCTAssertEqual(h.samples.last?.time, 500)
    }
    func testConcurrentDecodeAndPresentationCallbacksAreCounted() {
        let t = StreamTelemetry(at: 0)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            t.decoded(milliseconds: 2); t.enqueued(waitMs: 3)
        }
        let s = t.roll(at: 1)
        XCTAssertEqual(s.decodedFPS, 1000); XCTAssertEqual(s.shownFPS, 1000)
        XCTAssertEqual(s.decodeMs, 2); XCTAssertEqual(s.presentationMs, 3)
    }
    func testGraphModeRoundTripsWithoutChangingSavedBufferChoice() throws {
        var profile = StreamProfile(hostID: "test", name: "Test stream")
        profile.video.frameBuffer = 2
        profile.window.statistics = .detailed
        profile.window.graphs = true
        let loaded = try JSONDecoder().decode(StreamProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(loaded.window.statistics, .detailed); XCTAssertTrue(loaded.window.graphs)
        XCTAssertEqual(loaded.video.frameBuffer, 2)
        let old = try JSONDecoder().decode(StreamProfile.Window.self, from: Data(#"{"statistics":"detailed"}"#.utf8))
        XCTAssertEqual(old.statistics, .detailed)
        XCTAssertFalse(old.graphs)
    }
    func testGraphsAndTextAreIndependentLiveSettings() throws {
        let original = StreamProfile(hostID: "test", name: "Test")
        var p = original; p.window.graphs = true
        XCTAssertEqual(p.window.statistics, .off)
        XCTAssertEqual(p.settingChanges(from: original).live, ["performance graphs"])
        XCTAssertTrue(p.settingChanges(from: original).nextStream.isEmpty)
        let graphOnly = try JSONDecoder().decode(StreamProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(graphOnly.window.statistics, .off); XCTAssertTrue(graphOnly.window.graphs)
        p.window.graphs = false; p.window.statistics = .detailed
        let textOnly = try JSONDecoder().decode(StreamProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(textOnly.window.statistics, .detailed); XCTAssertFalse(textOnly.window.graphs)
    }
}
