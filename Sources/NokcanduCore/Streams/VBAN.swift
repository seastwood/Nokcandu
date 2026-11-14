// SPDX-License-Identifier: GPL-3.0-only
// VBAN (VB-Audio's network audio protocol): this Mac's microphone to a receiver such as VBAN Receptor or Voicemeeter,
// the way VBAN Talkie sends it. Uncompressed 16-bit PCM over UDP, port 6980 by default.
import Foundation

public struct VBANSettings: Codable, Hashable, Sendable {
    public var enabled = false
    /// Where to send; nil sends to the stream's host.
    public var address: String?
    public var port: UInt16 = 6980
    /// The receiver matches incoming audio by this name (VBAN's "Stream1" by default).
    public var streamName = "Stream1"
    public var channels = 1
    public var sampleRate = 48000
    /// A microphone's Core Audio unique ID; nil for the Mac's default input.
    public var inputDevice: String?
    /// Microphone processing, like VBAN Talkie's: gain in dB (−12…+24); noise gate and compressor amounts 0…1
    /// (0 off); equalizer bands in dB (−12…+12).
    public var gainDB: Double = 0
    public var gate: Double = 0
    public var compressor: Double = 0
    public var bassDB: Double = 0
    public var midDB: Double = 0
    public var trebleDB: Double = 0
    /// Samples per channel in each packet: smaller is lower latency, larger copes better with a busy network.
    public var packetSamples = 256
    /// Send only while the push-to-talk key or button is held.
    public var pushToTalk = false
    /// The push-to-talk input: "key:<Mac key code>" or "mouse:<button number>" (3, 4: side buttons).
    public var pushToTalkInput: String?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, address, port, streamName, channels, sampleRate, inputDevice
        case gainDB, gate, compressor, bassDB, midDB, trebleDB, packetSamples, pushToTalk, pushToTalkInput
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        address = try c.decodeIfPresent(String.self, forKey: .address)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 6980
        streamName = try c.decodeIfPresent(String.self, forKey: .streamName) ?? "Stream1"
        channels = min(2, max(1, try c.decodeIfPresent(Int.self, forKey: .channels) ?? 1))
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48000
        inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        gate = try c.decodeIfPresent(Double.self, forKey: .gate) ?? 0
        compressor = try c.decodeIfPresent(Double.self, forKey: .compressor) ?? 0
        bassDB = try c.decodeIfPresent(Double.self, forKey: .bassDB) ?? 0
        midDB = try c.decodeIfPresent(Double.self, forKey: .midDB) ?? 0
        trebleDB = try c.decodeIfPresent(Double.self, forKey: .trebleDB) ?? 0
        packetSamples = [64, 128, 256].contains(try c.decodeIfPresent(Int.self, forKey: .packetSamples) ?? 256) ? (try c.decodeIfPresent(Int.self, forKey: .packetSamples) ?? 256) : 256
        pushToTalk = try c.decodeIfPresent(Bool.self, forKey: .pushToTalk) ?? false
        pushToTalkInput = try c.decodeIfPresent(String.self, forKey: .pushToTalkInput)
    }
}

extension VBANSettings {
    /// The same connection and format (what restarting the sender would change); processing and push-to-talk aside.
    public func sameTransport(as o: VBANSettings) -> Bool {
        enabled == o.enabled && address == o.address && port == o.port && streamName == o.streamName && channels == o.channels
            && sampleRate == o.sampleRate && inputDevice == o.inputDevice && packetSamples == o.packetSamples
    }
}

/// The microphone chain: equalizer, gain, noise gate, compressor, then a safety limit. Float samples −1…1,
/// interleaved; state is kept between calls.
public struct VBANProcessor: Sendable {
    public var settings: VBANSettings
    public let sampleRate: Double
    public let channels: Int
    private var bands: [Biquad]
    private var bandState: [[Biquad.State]]
    private var gateEnv: Double = 0, gateGain: Double = 0, compEnv: Double = 0
    /// Peak of the processed signal since last read (for the meter), 0…1.
    public private(set) var peak: Float = 0

    public init(settings: VBANSettings, sampleRate: Double, channels: Int) {
        self.settings = settings; self.sampleRate = sampleRate; self.channels = max(1, channels)
        bands = Self.makeBands(settings, sampleRate)
        bandState = Array(repeating: Array(repeating: Biquad.State(), count: 3), count: max(1, channels))
    }

    public mutating func update(_ s: VBANSettings) {
        let eqChanged = s.bassDB != settings.bassDB || s.midDB != settings.midDB || s.trebleDB != settings.trebleDB
        settings = s
        if eqChanged { bands = Self.makeBands(s, sampleRate) }
    }

    public mutating func takePeak() -> Float { defer { peak = 0 }; return peak }

    static func makeBands(_ s: VBANSettings, _ rate: Double) -> [Biquad] {
        [Biquad.shelf(low: true, frequency: 150, gainDB: s.bassDB, rate: rate),
         Biquad.peak(frequency: 1500, q: 0.9, gainDB: s.midDB, rate: rate),
         Biquad.shelf(low: false, frequency: 5000, gainDB: s.trebleDB, rate: rate)]
    }

    public mutating func process(_ x: inout [Float]) {
        let gain = pow(10, settings.gainDB / 20)
        let eq = settings.bassDB != 0 || settings.midDB != 0 || settings.trebleDB != 0
        // Gate: opens above a threshold from −70 dBFS (just on) to −30 dBFS (full); fast open, slow close.
        let gateOpen = settings.gate > 0 ? pow(10, (-70 + 40 * settings.gate) / 20) : 0
        let att = exp(-1 / (0.002 * sampleRate)), rel = exp(-1 / (0.15 * sampleRate))
        // Compressor: threshold from −10 dBFS down to −40 dBFS and ratio 1.5…6 as the amount rises, with make-up gain.
        let compOn = settings.compressor > 0
        let threshDB = -10 - 30 * settings.compressor, ratio = 1.5 + 4.5 * settings.compressor
        let makeup = compOn ? pow(10, (-threshDB * (1 - 1 / ratio)) * 0.5 / 20) : 1
        let catt = exp(-1 / (0.005 * sampleRate)), crel = exp(-1 / (0.12 * sampleRate))
        let frames = x.count / channels
        for f in 0..<frames {
            var level: Double = 0
            for c in 0..<channels {
                var v = Double(x[f * channels + c])
                if eq { for b in 0..<3 { v = bands[b].run(v, &bandState[c][b]) } }
                v *= gain
                x[f * channels + c] = Float(v)
                level = max(level, abs(v))
            }
            var g = 1.0
            if gateOpen > 0 {
                gateEnv = level > gateEnv ? level : gateEnv * rel + level * (1 - rel)
                let target = gateEnv >= gateOpen ? 1.0 : 0.0
                gateGain = target > gateGain ? target + (gateGain - target) * att : target + (gateGain - target) * rel
                g *= gateGain
            }
            if compOn {
                compEnv = level > compEnv ? catt * compEnv + (1 - catt) * level : crel * compEnv + (1 - crel) * level
                let envDB = 20 * log10(max(compEnv, 1e-9))
                if envDB > threshDB { g *= pow(10, (threshDB + (envDB - threshDB) / ratio - envDB) / 20) }
                g *= makeup
            }
            for c in 0..<channels {
                var v = Double(x[f * channels + c]) * g
                if v > 0.98 { v = 0.98 } else if v < -0.98 { v = -0.98 }     // never wrap the 16-bit samples
                x[f * channels + c] = Float(v)
                peak = max(peak, Float(abs(v)))
            }
        }
    }
}

/// RBJ cookbook biquads for the equalizer.
public struct Biquad: Sendable {
    public struct State: Sendable { var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0 }
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    func run(_ x: Double, _ s: inout State) -> Double {
        let y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
        s.x2 = s.x1; s.x1 = x; s.y2 = s.y1; s.y1 = y
        return y
    }

    static func shelf(low: Bool, frequency: Double, gainDB: Double, rate: Double) -> Biquad {
        guard gainDB != 0 else { return Biquad() }
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * frequency / rate, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt(2.0), sq = 2 * sqrt(a) * alpha
        var q = Biquad()
        let a0: Double
        if low {
            q.b0 = a * ((a + 1) - (a - 1) * cw + sq); q.b1 = 2 * a * ((a - 1) - (a + 1) * cw); q.b2 = a * ((a + 1) - (a - 1) * cw - sq)
            a0 = (a + 1) + (a - 1) * cw + sq; q.a1 = -2 * ((a - 1) + (a + 1) * cw); q.a2 = (a + 1) + (a - 1) * cw - sq
        } else {
            q.b0 = a * ((a + 1) + (a - 1) * cw + sq); q.b1 = -2 * a * ((a - 1) + (a + 1) * cw); q.b2 = a * ((a + 1) + (a - 1) * cw - sq)
            a0 = (a + 1) - (a - 1) * cw + sq; q.a1 = 2 * ((a - 1) - (a + 1) * cw); q.a2 = (a + 1) - (a - 1) * cw - sq
        }
        q.b0 /= a0; q.b1 /= a0; q.b2 /= a0; q.a1 /= a0; q.a2 /= a0
        return q
    }

    static func peak(frequency: Double, q qf: Double, gainDB: Double, rate: Double) -> Biquad {
        guard gainDB != 0 else { return Biquad() }
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * qf), cw = cos(w)
        var q = Biquad()
        let a0 = 1 + alpha / a
        q.b0 = (1 + alpha * a) / a0; q.b1 = -2 * cw / a0; q.b2 = (1 - alpha * a) / a0; q.a1 = -2 * cw / a0; q.a2 = (1 - alpha / a) / a0
        return q
    }
}

/// Builds VBAN audio packets: a 28-byte header, then interleaved little-endian 16-bit samples.
public struct VBANPacketizer: Sendable {
    /// VBAN's sample-rate table; the header carries the index.
    public static let rates = [6000, 12000, 24000, 48000, 96000, 192000, 384000, 8000, 16000, 32000, 64000, 128000,
                               256000, 512000, 11025, 22050, 44100, 88200, 176400, 352800, 705600]
    public static let headerSize = 28
    /// At most 256 samples per channel and 1436 bytes of audio in one packet.
    public static let maxSamples = 256, maxPayload = 1436

    public let streamName: String
    public let sampleRate: Int
    public let channels: Int
    public private(set) var frameCounter: UInt32 = 0
    private var pending: [Int16] = []

    private let packetSamples: Int

    public init(streamName: String, sampleRate: Int, channels: Int, packetSamples: Int = 256) {
        self.streamName = streamName
        self.sampleRate = Self.rates.contains(sampleRate) ? sampleRate : 48000
        self.channels = min(2, max(1, channels))
        self.packetSamples = max(16, min(Self.maxSamples, packetSamples))
    }

    /// Samples per channel in each packet (256 like VBAN Talkie by default), within VBAN's payload limit.
    public var samplesPerPacket: Int { min(packetSamples, Self.maxPayload / (2 * channels)) }

    public func header(samples: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: Self.headerSize)
        h[0] = 0x56; h[1] = 0x42; h[2] = 0x41; h[3] = 0x4E                 // "VBAN"
        h[4] = UInt8(Self.rates.firstIndex(of: sampleRate) ?? 3) & 0x1F    // sub-protocol 0 = audio
        h[5] = UInt8(samples - 1)
        h[6] = UInt8(channels - 1)
        h[7] = 0x01                                                         // 16-bit integer PCM
        let name = Array(streamName.utf8.prefix(16))
        for (i, b) in name.enumerated() { h[8 + i] = b }
        let n = frameCounter
        h[24] = UInt8(n & 0xFF); h[25] = UInt8((n >> 8) & 0xFF); h[26] = UInt8((n >> 16) & 0xFF); h[27] = UInt8(n >> 24)
        return h
    }

    /// Adds interleaved samples to send later with `nextPacket()` (paced sending). Keeps at most `maxBacklog`
    /// packets' worth, dropping the oldest, so a stall doesn't build up delay.
    public mutating func append(_ samples: [Int16], maxBacklog: Int = 5) {
        pending += samples
        let per = samplesPerPacket * channels, limit = per * maxBacklog
        if pending.count > limit { pending.removeFirst(pending.count - limit) }
    }

    /// Whole packets waiting.
    public var backlog: Int { pending.count / (samplesPerPacket * channels) }

    /// The next packet, if a whole one is waiting.
    public mutating func nextPacket() -> Data? {
        let per = samplesPerPacket * channels
        guard pending.count >= per else { return nil }
        var d = Data(header(samples: samplesPerPacket))
        d.reserveCapacity(Self.headerSize + per * 2)
        for s in pending[0..<per] { d.append(UInt8(truncatingIfNeeded: s)); d.append(UInt8(truncatingIfNeeded: s >> 8)) }
        pending.removeFirst(per)
        frameCounter &+= 1
        return d
    }

    /// Peak level of samples in dBFS (−∞ as −120), for the log.
    public static func peakDB(_ samples: [Int16]) -> Double {
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        return peak == 0 ? -120 : 20 * log10(Double(peak) / 32768)
    }

    /// Adds interleaved samples and returns every whole packet now ready.
    public mutating func packets(adding samples: [Int16]) -> [Data] {
        pending += samples
        var out: [Data] = []
        let per = samplesPerPacket * channels
        var start = 0
        while pending.count - start >= per {
            var d = Data(header(samples: samplesPerPacket))
            d.reserveCapacity(Self.headerSize + per * 2)
            for s in pending[start..<(start + per)] { d.append(UInt8(truncatingIfNeeded: s)); d.append(UInt8(truncatingIfNeeded: s >> 8)) }
            out.append(d)
            frameCounter &+= 1
            start += per
        }
        pending.removeFirst(start)
        return out
    }
}
