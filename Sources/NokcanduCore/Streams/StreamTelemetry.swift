import Foundation

/// Bounded per-interval aggregates. No per-frame history, logging, network I/O or UI work.
public final class StreamTelemetry: @unchecked Sendable {
    public struct Sample: Identifiable, Sendable {
        public var id: Double { time }
        public var time = 0.0, duration = 0.0
        public var receivedFPS = 0.0, decodedFPS = 0.0, shownFPS = 0.0
        public var bitrateMbps = 0.0, peakBitrateMbps = 0.0, bufferedFrames = 0.0
        public var hostMinMs: Double?, hostMs: Double?, hostMaxMs: Double?
        public var decodeMinMs: Double?, decodeMs: Double?, decodeMaxMs: Double?
        public var assemblyMs: Double?, queueMs: Double?, presentationMs: Double?, presentationMaxMs: Double?
        public var arrivalGapMaxMs: Double?, displayGapMaxMs: Double?, enqueueGapMaxMs: Double?
        public var networkMs: Double?, networkVariationMs: Double?
        public var networkDropped = 0, dropped = 0, pacedDrops = 0
        public var networkDropPercent: Double?, pacingDropPercent: Double?
        /// From the end of decoding to the picture being on screen, and from the frame's first packet arriving to it
        /// being on screen. Measured (the Metal renderer reports when each frame was presented) or estimated (the
        /// display layer can't say: the next display refresh after the frame was handed over, plus one refresh for the
        /// window server).
        public var screenMs: Double?, screenMaxMs: Double?, clientMs: Double?, clientMaxMs: Double?
        public var screenMeasured = false
        /// Since the stream started.
        public var whole = Whole()
        public init() {}
    }

    /// Averages over the whole stream so far, and the time 99% of frames stayed under (bounded: fixed bins).
    public struct Whole: Sendable {
        public var seconds = 0.0, shownFPS: Double?
        public var decodeMs: Double?, screenMs: Double?, clientMs: Double?, hostMs: Double?, networkMs: Double?
        public var screenP99Ms: Double?, clientP99Ms: Double?
        public init() {}
    }

    /// Frame times in 0.25 ms bins up to 200 ms (the last bin holds anything slower): 800 counters, no history.
    struct Histogram {
        static let bin = 0.25, count = 800
        var bins = [Int](repeating: 0, count: Histogram.count), total = 0
        mutating func add(_ ms: Double) {
            guard ms.isFinite, ms >= 0 else { return }
            bins[min(Self.count - 1, Int(ms / Self.bin))] += 1; total += 1
        }
        /// The upper edge of the bin where `fraction` of samples are at or below.
        func percentile(_ fraction: Double) -> Double? {
            guard total > 0 else { return nil }
            let target = Int((Double(total) * fraction).rounded(.up))
            var seen = 0
            for (i, n) in bins.enumerated() { seen += n; if seen >= target { return Double(i + 1) * Self.bin } }
            return Double(Self.count) * Self.bin
        }
    }
    private struct Metric {
        var n = 0, sum = 0.0, min = Double.infinity, max = 0.0
        mutating func add(_ x: Double) {
            guard x.isFinite, x >= 0 else { return }
            n += 1; sum += x; min = Swift.min(min, x); max = Swift.max(max, x)
        }
        var mean: Double? { n > 0 ? sum / Double(n) : nil }
        var minimum: Double? { n > 0 ? min : nil }
        var maximum: Double? { n > 0 ? max : nil }
    }
    private let lock = NSLock()
    private var start: Double
    private var lastFrame: UInt32?, lastArrival: Double?, lastDisplay: Double?, lastEnqueue: Double?
    private var received = 0, decoded = 0, shown = 0, bytes = 0
    private var totalReceived = 0, totalMissing = 0, totalDecodeDrops = 0, totalPacingDrops = 0
    private var host = Metric(), decode = Metric(), assembly = Metric(), queue = Metric(), presentation = Metric()
    private var arrivalGap = Metric(), displayGap = Metric(), enqueueGap = Metric(), buffered = Metric()
    private var screen = Metric(), client = Metric(), screenMeasured = false
    // Whole stream: never reset by `roll`.
    private let began: Double
    private var allShown = 0, allDecode = Metric(), allScreen = Metric(), allClient = Metric(), allHost = Metric(), allNetwork = Metric()
    private var screenHistogram = Histogram(), clientHistogram = Histogram()
    private var peak = 0.0
    public static let settleSeconds = 3.0
    public init(at time: Double = ProcessInfo.processInfo.systemUptime) { start = time; began = time }

    public func receive(frame: UInt32, bytes length: Int, hostLatencyTenthsMs: UInt16,
                        assemblyMs: Double?, queueMs: Double?, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        received += 1; totalReceived += 1; bytes += max(0, length)
        if let previous = lastFrame {
            let step = frame &- previous
            // A backwards/reset sequence is not billions of network losses. Handle UInt32 wrap.
            if step > 0 && step < 0x80000000 {
                totalMissing += Int(step - 1)
                lastFrame = frame
            } else if step >= 0x80000000 { lastFrame = frame }
        } else { lastFrame = frame }
        if hostLatencyTenthsMs > 0 { host.add(Double(hostLatencyTenthsMs) / 10); allHost.add(Double(hostLatencyTenthsMs) / 10) }
        if let assemblyMs { assembly.add(assemblyMs) }
        if let queueMs { queue.add(queueMs) }
        if let lastArrival { arrivalGap.add((time - lastArrival) * 1000) }
        lastArrival = time
    }
    public func decoded(milliseconds: Double) {
        lock.lock(); defer { lock.unlock() }; decoded += 1; decode.add(milliseconds); allDecode.add(milliseconds)
    }
    public func enqueued(waitMs: Double, at time: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }; shown += 1; allShown += 1; presentation.add(waitMs)
        if time.isFinite {
            if let lastEnqueue { enqueueGap.add((time - lastEnqueue) * 1000) }
            lastEnqueue = time
        }
    }
    public func displayTick(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if let lastDisplay { displayGap.add((time - lastDisplay) * 1000) }
        lastDisplay = time
    }
    /// A frame reached the screen: `decodeToScreenMs` after it was decoded, `receiveToScreenMs` after its first
    /// packet arrived. `measured` false for an estimate.
    public func onScreen(decodeToScreenMs: Double, receiveToScreenMs: Double?, measured: Bool,
                         at time: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        screen.add(decodeToScreenMs)
        if let receiveToScreenMs { client.add(receiveToScreenMs) }
        // The whole-stream figures leave out the first seconds, while the picture first appears and the decoder and
        // display settle (they put the stream's 99% figure at 46 ms, November 19).
        if time - began >= Self.settleSeconds {
            allScreen.add(decodeToScreenMs); screenHistogram.add(decodeToScreenMs)
            if let receiveToScreenMs { allClient.add(receiveToScreenMs); clientHistogram.add(receiveToScreenMs) }
        }
        screenMeasured = measured
    }
    public func buffer(depth: Int) { lock.lock(); defer { lock.unlock() }; buffered.add(Double(max(0, depth))) }
    public func dropped() { lock.lock(); defer { lock.unlock() }; totalDecodeDrops += 1 }
    public func paced(dropped n: Int) { lock.lock(); defer { lock.unlock() }; totalPacingDrops += max(0, n) }

    public func roll(at time: Double, networkMs: Double? = nil, variationMs: Double? = nil) -> Sample {
        lock.lock(); defer { lock.unlock() }
        guard time.isFinite, time > start else { return Sample() }
        var s = Sample(); s.time = time; s.duration = time - start
        s.receivedFPS = Double(received) / s.duration; s.decodedFPS = Double(decoded) / s.duration; s.shownFPS = Double(shown) / s.duration
        s.bitrateMbps = Double(bytes) * 8 / s.duration / 1_000_000
        peak = max(peak, s.bitrateMbps); s.peakBitrateMbps = peak
        s.bufferedFrames = buffered.mean ?? 0
        s.hostMinMs = host.minimum; s.hostMs = host.mean; s.hostMaxMs = host.maximum
        s.decodeMinMs = decode.minimum; s.decodeMs = decode.mean; s.decodeMaxMs = decode.maximum
        s.assemblyMs = assembly.mean; s.queueMs = queue.mean; s.presentationMs = presentation.mean
        s.presentationMaxMs = presentation.maximum; s.enqueueGapMaxMs = enqueueGap.maximum
        s.arrivalGapMaxMs = arrivalGap.maximum; s.displayGapMaxMs = displayGap.maximum
        s.networkMs = networkMs; s.networkVariationMs = variationMs
        s.screenMs = screen.mean; s.screenMaxMs = screen.maximum; s.clientMs = client.mean; s.clientMaxMs = client.maximum
        s.screenMeasured = screenMeasured
        if let networkMs { allNetwork.add(networkMs) }
        var w = Whole()
        w.seconds = time - began
        if w.seconds > 0 { w.shownFPS = Double(allShown) / w.seconds }
        w.decodeMs = allDecode.mean; w.screenMs = allScreen.mean; w.clientMs = allClient.mean
        w.hostMs = allHost.mean; w.networkMs = allNetwork.mean
        w.screenP99Ms = screenHistogram.percentile(0.99); w.clientP99Ms = clientHistogram.percentile(0.99)
        s.whole = w
        s.networkDropped = totalMissing; s.dropped = totalDecodeDrops; s.pacedDrops = totalPacingDrops
        // Use one lifetime denominator: asynchronous decode/pacing can cross an interval boundary.
        let expected = totalReceived + totalMissing
        if expected > 0 {
            s.networkDropPercent = Double(totalMissing) * 100 / Double(expected)
            s.pacingDropPercent = Double(totalPacingDrops) * 100 / Double(expected)
        }
        start = time; received = 0; decoded = 0; shown = 0; bytes = 0
        host = Metric(); decode = Metric(); assembly = Metric(); queue = Metric(); presentation = Metric()
        arrivalGap = Metric(); displayGap = Metric(); enqueueGap = Metric(); buffered = Metric()
        screen = Metric(); client = Metric()
        return s
    }
}

public struct StreamTelemetryHistory: Sendable {
    public private(set) var samples: [StreamTelemetry.Sample] = []
    public init() {}
    public mutating func append(_ sample: StreamTelemetry.Sample) {
        guard sample.time.isFinite, sample.duration > 0, samples.last.map({ sample.time > $0.time }) ?? true else { return }
        samples.append(sample)
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }
}
