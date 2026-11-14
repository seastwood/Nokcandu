import XCTest
@testable import NokcanduCore

/// November 13, 2026: with the resting thumb fixed, the cursor still jittered while the thumb moved: the pad's
/// noise (6–8 px on every report at the user's sensitivity) rode on the movement. The noise is filtered in
/// proportion to how noisy the pad is, without holding back a swipe.
final class MovingThumbTests: XCTestCase {
    private func userSettings() -> PadSteamTrackpadSettings {
        var s = PadSteamTrackpadSettings(mode: .trackball)
        s.sensitivity = 647; s.sensitivityX = 1335; s.sensitivityY = 1404; s.smoothing = 0; s.steadiness = 0; s.rotation = 0
        return s
    }

    /// The recorded thumb through the user's settings: how much each report's step differs from the one before
    /// (jitter), for the cursor and for the raw readings over the same reports, and the distance covered.
    /// Counted separately below and above half a pad-width a second (by the finger's speed over 56 ms around
    /// each report): jitter shows on slow movement, and a fast one must stay as direct as it was.
    func testTheRecordedMovingThumbJittersFarLess() {
        let all = MovingThumbRecording.samples
        func fingerSpeed(_ i: Int) -> Double {
            let a = all[max(0, i - 3)], b = all[min(all.count - 1, i + 3)]
            guard b.t - a.t < 0.1, b.t > a.t else { return 9 }
            return hypot(Double(b.x - a.x), Double(b.y - a.y)) / 65534 / (b.t - a.t)
        }
        var slow = (rough: 0.0, raw: 0.0, n: 0), fast = (rough: 0.0, raw: 0.0, n: 0)
        var pad = PadSteamTrackpad(); let s = userSettings()
        var last: (t: Double, x: Int, y: Int)?, lastStep: (out: (Double, Double), raw: (Double, Double))?
        var travel = (0.0, 0.0), rawTravel = (0.0, 0.0)
        for (i, p) in all.enumerated() {
            if let l = last, p.t - l.t > 0.05 { _ = pad.touch(down: false, x: 0, y: 0, at: l.t + 0.008, settings: s); last = nil; lastStep = nil }
            let m = pad.touch(down: true, x: (Double(p.x) / 32767 + 1) / 2, y: (1 - Double(p.y) / 32767) / 2, at: p.t, settings: s)
            defer { last = p }
            guard let l = last, m.fx != 0 || m.fy != 0 else { lastStep = nil; continue }
            let raw = (Double(p.x - l.x) / 65534 * 1335, -Double(p.y - l.y) / 65534 * 1404)
            travel.0 += m.fx; travel.1 += m.fy; rawTravel.0 += raw.0; rawTravel.1 += raw.1
            if let b = lastStep {
                let r = hypot(m.fx - b.out.0, m.fy - b.out.1), rr = hypot(raw.0 - b.raw.0, raw.1 - b.raw.1)
                if fingerSpeed(i) < 0.5 { slow.rough += r; slow.raw += rr; slow.n += 1 } else { fast.rough += r; fast.raw += rr; fast.n += 1 }
            }
            lastStep = ((m.fx, m.fy), raw)
        }
        print("moving thumb jitter per report: slow \(slow.rough / Double(slow.n)) px (raw \(slow.raw / Double(slow.n)), \(slow.n) reports), fast \(fast.rough / Double(fast.n)) px (raw \(fast.raw / Double(fast.n)), \(fast.n) reports); travel \(travel) raw \(rawTravel)")
        XCTAssertGreaterThan(slow.n, 150); XCTAssertGreaterThan(fast.n, 50)
        XCTAssertLessThan(slow.rough, slow.raw * 0.5, "slow movement: \(slow.rough / Double(slow.n)) px a report, raw \(slow.raw / Double(slow.n))")
        XCTAssertLessThanOrEqual(fast.rough, fast.raw, "fast movement is no rougher")
        XCTAssertGreaterThan(pad.noiseLevel, PadSteamTrackpad.quietNoise, "the pad's noise was noticed")
        // Nothing is lost: the cursor covers the distance the raw readings did (to within the filter's last few pixels).
        XCTAssertEqual(travel.0, rawTravel.0, accuracy: 25); XCTAssertEqual(travel.1, rawTravel.1, accuracy: 25)
    }

    /// A noisy pad (like the recorded one) at rest, then a fast swipe that stops: the cursor is at most a few
    /// pixels (about 2 ms) behind the finger when it stops, and never runs past it.
    func testASwipeOnANoisyPadIsNotHeldBack() {
        var s = PadSteamTrackpadSettings(mode: .mouse); s.sensitivity = 1000; s.smoothing = 0
        var pad = PadSteamTrackpad(), seed: UInt64 = 11, t = 0.0, out = 0.0
        func jitter() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.009 }
        func feed(_ x: Double) { t += 0.008; out += pad.touch(down: true, x: x + jitter(), y: 0.5 + jitter(), at: t, settings: s).fx }
        _ = pad.touch(down: true, x: 0.25, y: 0.5, at: t, settings: s)
        for _ in 0..<150 { feed(0.25) }
        XCTAssertGreaterThan(pad.noiseLevel, PadSteamTrackpad.noisyNoise, "the filter is fully on")
        for k in 1...25 { feed(0.25 + Double(k) * 0.02) }          // 2.5 pads a second
        let atStop = out
        var furthest = out
        for _ in 0..<40 { feed(0.75); furthest = max(furthest, out) }
        XCTAssertGreaterThan(atStop, 440, "the swipe arrived (less the start threshold)")
        XCTAssertLessThan(out - atStop, 12, "behind the finger when it stopped: \(out - atStop) px")
        XCTAssertLessThan(furthest - out, 6, "no overshoot")
    }

    /// A quiet pad is left exactly raw: the filter only ever answers noise.
    func testAQuietPadStaysRaw() {
        var s = PadSteamTrackpadSettings(mode: .mouse); s.sensitivity = 1000; s.smoothing = 0
        var pad = PadSteamTrackpad(), t = 0.0, x = 0.3
        _ = pad.touch(down: true, x: x, y: 0.5, at: t, settings: s)
        for k in 0..<200 {
            t += 0.008; let step = 0.0005 + 0.002 * abs(sin(Double(k) / 15)); x += step
            let m = pad.touch(down: true, x: min(1, x), y: 0.5, at: t, settings: s)
            if k > 20, x < 1 { XCTAssertEqual(m.fx, step * 1000, accuracy: 1e-9) }
        }
        XCTAssertLessThan(pad.noiseLevel, PadSteamTrackpad.quietNoise)
    }
}
