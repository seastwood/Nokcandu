// SPDX-License-Identifier: GPL-3.0-only
// Plays the host's sound: Opus (stereo, 5.1 or 7.1) decoded with libopus into a small ring buffer that
// an AVAudioEngine source node drains. Extra buffered audio is dropped so sound stays in step with the picture.
import AVFoundation
import CoreAudio
import NokcanduStreamCore
import os

final class StreamAudioPlayer: @unchecked Sendable {
    private var decoder: OpaquePointer?
    private var engine: AVAudioEngine?
    private var channels = 2, sampleRate = 48000, samplesPerFrame = 240
    private var scratch: [Float] = []
    private let ring = StreamAudioRing()
    var volume: Float = 1 { didSet { engine?.mainMixerNode.outputVolume = volume } }
    /// The output to play on (Core Audio UID), or nil for the Mac's default. Changing it moves the sound at once.
    var outputDevice: String? {
        didSet { if oldValue != outputDevice, engine != nil { DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartOutput(reason: "a different output was chosen") } } }
    }
    /// Most audio to keep queued (seconds) before dropping the oldest.
    var bufferLimit = 0.06
    // What happened to the sound, logged every 5 seconds (the stream log is how sound problems get found).
    private var decodedPackets = 0, failedPackets = 0, lastFailure: Int32 = 0, peak: Float = 0
    private var lastReport = Date()
    private var source: AVAudioSourceNode?
    private var format: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private static var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let engineLock = NSLock()

    func setup(audioConfiguration: Int32, opus: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 {
        var cfg = opus
        channels = Int(cfg.channelCount); sampleRate = Int(cfg.sampleRate); samplesPerFrame = Int(cfg.samplesPerFrame)
        let mapping = withUnsafeBytes(of: &cfg.mapping) { Array($0.bindMemory(to: UInt8.self)) }
        decoder = mapping.withUnsafeBufferPointer {
            nk_opus_create(cfg.sampleRate, cfg.channelCount, cfg.streams, cfg.coupledStreams, $0.baseAddress)
        }
        guard decoder != nil else { StreamLog.shared.add("Audio: couldn't set up the decoder"); return -1 }
        scratch = [Float](repeating: 0, count: 5760 * channels)
        ring.reset(capacity: sampleRate * channels / 2, channels: channels)

        let layoutTag: AudioChannelLayoutTag
        switch channels {
        case 6: layoutTag = kAudioChannelLayoutTag_WAVE_5_1_A
        case 8: layoutTag = kAudioChannelLayoutTag_WAVE_7_1
        default: layoutTag = kAudioChannelLayoutTag_Stereo
        }
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else { return -1 }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), interleaved: false, channelLayout: layout)
        let ring = self.ring, ch = channels
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            ring.read(frames: Int(frames), channels: ch) { c, i, v in
                buffers[c].mData!.assumingMemoryBound(to: Float.self)[i] = v
            }
            return noErr
        }
        self.source = source
        self.format = format
        let e = AVAudioEngine()
        selectOutput(e)
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = volume
        do { try e.start() } catch { StreamLog.shared.add("Audio: couldn't start the Mac's sound output (\(error.localizedDescription))"); return -1 }
        engine = e
        // macOS stops an engine's output when the audio setup changes (a device switched, another engine in this
        // app starting its microphone, as VBAN does); start it again, on whatever the output is now.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.restartOutput(reason: "the Mac's audio setup changed")
        }
        // Following the Mac's default output: move when it changes (switched in Control Center, headphones plugged in).
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.outputDevice == nil else { return }
            self.restartOutput(reason: "the Mac's default output changed")
        }
        defaultListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.global(qos: .userInitiated), listener)
        let out = e.outputNode.outputFormat(forBus: 0)
        StreamLog.shared.add("Audio: Opus \(channels) ch \(sampleRate) Hz, \(cfg.streams) streams (\(cfg.coupledStreams) coupled), \(samplesPerFrame) samples a packet; playing to \(currentOutputName)\(outputDevice == nil ? " (the Mac's default)" : "") (\(out.channelCount) ch \(Int(out.sampleRate)) Hz), volume \(volume)")
        return 0
    }

    func play(_ data: UnsafeMutablePointer<CChar>?, length: Int32) {
        guard let decoder else { return }
        let n = scratch.withUnsafeMutableBufferPointer { out in
            nk_opus_decode(decoder, data.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) }, length, out.baseAddress, Int32(5760))
        }
        if n <= 0 { failedPackets += 1; lastFailure = n; report(); return }
        decodedPackets += 1
        scratch.withUnsafeBufferPointer { b in for i in 0..<(Int(n) * channels) { peak = max(peak, abs(b[i])) } }
        report()
        let limit = Int(bufferLimit * Double(sampleRate))
        scratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: Int(n), keepAtMost: max(limit, Int(n) * 2)) }
    }

    private func restartOutput(reason: String) {
        engineLock.lock(); defer { engineLock.unlock() }
        guard let e = engine, let source, let format else { return }
        e.stop()
        selectOutput(e)
        e.disconnectNodeOutput(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = volume
        do {
            try e.start()
            StreamLog.shared.add("Audio: output restarted (\(reason)); playing to \(currentOutputName)")
        } catch {
            StreamLog.shared.add("Audio: couldn't restart the output (\(reason)): \(error.localizedDescription)")
        }
    }

    private func report() {
        guard Date().timeIntervalSince(lastReport) >= 5 else { return }
        lastReport = Date()
        // A check in case macOS stopped the output without saying so.
        if engine?.isRunning == false { DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartOutput(reason: "it had stopped") } }
        let db = peak > 0 ? String(format: "%.0f dBFS", 20 * log10(Double(peak))) : "silent"
        StreamLog.shared.add("Audio: \(decodedPackets) packets decoded\(failedPackets > 0 ? ", \(failedPackets) failed (Opus error \(lastFailure))" : ""), peak \(db), \(Int(queuedMs)) ms queued, output \(engine?.isRunning == true ? "running" : "stopped")")
        decodedPackets = 0; failedPackets = 0; peak = 0
    }

    /// Points the engine at the chosen output, or leaves it on the Mac's default (also when the chosen one is gone).
    private func selectOutput(_ e: AVAudioEngine) {
        guard let unit = e.outputNode.audioUnit else { return }
        var id = AudioDeviceID(0)
        if let uid = outputDevice {
            if let chosen = Self.outputDevices().first(where: { $0.uid == uid }) { id = chosen.id }
            else { StreamLog.shared.add("Audio: the chosen output isn't connected; playing to the Mac's default output") }
        }
        if id == 0 {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        }
        if id != 0 { AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) }
        currentOutputName = Self.deviceName(id)
    }
    private(set) var currentOutputName = ""

    /// The Mac's sound outputs: (Core Audio ID, UID, name).
    static func outputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var n = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            var uid: Unmanaged<CFString>?
            var u = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &u, &uid) == noErr, let uidValue = uid?.takeRetainedValue() else { return nil }
            return (id, uidValue as String, deviceName(id))
        }
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard id != 0, AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "unknown" }
        return n as String
    }

    static func outputDeviceName() -> String {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "unknown" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "unknown" }
        return n as String
    }

    func cleanup() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let l = defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.global(qos: .userInitiated), l)
            defaultListener = nil
        }
        engineLock.lock()
        engine?.stop(); engine = nil
        engineLock.unlock()
        if let d = decoder { nk_opus_destroy(d) }
        decoder = nil
    }

    /// Queued audio in milliseconds.
    var queuedMs: Double { Double(ring.frames) / Double(sampleRate) * 1000 }
}

/// Interleaved float frames between the network thread and the audio thread.
final class StreamAudioRing: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var buffer: [Float] = []
    private var head = 0, count = 0, channels = 2
    private var capacityFrames = 0

    func reset(capacity samples: Int, channels: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.channels = channels
        capacityFrames = samples / channels
        buffer = [Float](repeating: 0, count: capacityFrames * channels)
        head = 0; count = 0
    }

    var frames: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return count }

    func write(_ p: UnsafePointer<Float>, frames n: Int, keepAtMost: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard capacityFrames > 0 else { return }
        // Drop the oldest audio rather than fall behind.
        let excess = count + n - min(keepAtMost, capacityFrames)
        if excess > 0 { let d = min(excess, count); head = (head + d) % capacityFrames; count -= d }
        for f in 0..<min(n, capacityFrames) {
            let slot = (head + count) % capacityFrames
            for c in 0..<channels { buffer[slot * channels + c] = p[f * channels + c] }
            count += 1
        }
    }

    func read(frames n: Int, channels ch: Int, _ put: (Int, Int, Float) -> Void) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<n {
            if count > 0 {
                for c in 0..<ch { put(c, i, buffer[head * channels + c]) }
                head = (head + 1) % capacityFrames; count -= 1
            } else {
                for c in 0..<ch { put(c, i, 0) }
            }
        }
    }
}
