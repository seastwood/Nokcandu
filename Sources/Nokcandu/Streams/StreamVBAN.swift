// SPDX-License-Identifier: GPL-3.0-only
// Sends this Mac's microphone over VBAN while a stream runs, like VBAN Talkie.
import AVFoundation
import CoreAudio
import Network
import NokcanduCore
import os

final class StreamVBANSender: @unchecked Sendable {
    private let settings: VBANSettings
    private let destination: String
    private var engine: AVAudioEngine?
    private var connection: NWConnection?
    private var converter: AVAudioConverter?
    private var packetizer: VBANPacketizer
    private let queue = DispatchQueue(label: "nokcandu.vban", qos: .userInteractive)
    private(set) var sentPackets = 0
    private var timer: DispatchSourceTimer?
    private var peak: Double = -120, lastLevelLog = Date()
    private var processor: VBANProcessor?
    private var lock = os_unfair_lock()
    private var _muted = false, _talking = false, _meter: Float = 0
    /// Muted: silence is sent (so the receiver stays connected) until unmuted.
    var muted: Bool { get { withLock { _muted } } set { withLock { _muted = newValue } } }
    /// The push-to-talk key or button is held.
    var talking: Bool { get { withLock { _talking } } set { withLock { _talking = newValue } } }
    /// Level of what's being sent (0…1), for the meter; decays when silent.
    var meter: Float { withLock { _meter } }
    var transmitting: Bool { withLock { !_muted && (!live.pushToTalk || _talking) } }
    private func withLock<T>(_ f: () -> T) -> T { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return f() }

    /// Processing and gating settings change during a stream without restarting the sender.
    func update(_ s: VBANSettings) {
        queue.async { [weak self] in self?.processor?.update(s) }
        withLock { live = s }
    }
    private var live: VBANSettings

    init(settings: VBANSettings, hostAddress: String) {
        self.settings = settings
        live = settings
        let typed = settings.address?.trimmingCharacters(in: .whitespaces)
        destination = (typed?.isEmpty == false ? typed! : StreamAddress.split(hostAddress).host)
        packetizer = VBANPacketizer(streamName: settings.streamName.isEmpty ? "Stream1" : settings.streamName,
                                    sampleRate: settings.sampleRate, channels: settings.channels, packetSamples: settings.packetSamples)
    }

    /// Asks for the microphone if needed, then starts. `failed` reports a problem for the user.
    func start(failed: @escaping @MainActor (String) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        StreamLog.shared.add("VBAN: starting (microphone access: \(["not asked yet", "restricted", "declined", "allowed"][min(3, status.rawValue)]))")
        switch status {
        case .authorized: begin(failed: failed)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.begin(failed: failed) } else { failed("Microphone access was declined, so VBAN isn't sending. Allow it in System Settings → Privacy & Security → Microphone.") }
                }
            }
        default:
            Task { @MainActor in failed("VBAN isn't sending: Nokcandu isn't allowed to use the microphone. Allow it in System Settings → Privacy & Security → Microphone.") }
        }
    }

    private func begin(failed: @escaping @MainActor (String) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(destination), port: NWEndpoint.Port(rawValue: settings.port) ?? 6980, using: .udp)
        c.start(queue: queue)
        connection = c

        let e = AVAudioEngine()
        if let uid = settings.inputDevice, let id = Self.deviceID(uid: uid), let unit = e.inputNode.audioUnit {
            var dev = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = e.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(packetizer.sampleRate), channels: AVAudioChannelCount(packetizer.channels), interleaved: true),
              let conv = AVAudioConverter(from: input, to: target) else {
            Task { @MainActor in failed("VBAN: the microphone isn't available.") }
            return
        }
        converter = conv
        processor = VBANProcessor(settings: settings, sampleRate: Double(packetizer.sampleRate), channels: packetizer.channels)
        e.inputNode.installTap(onBus: 0, bufferSize: 512, format: input) { [weak self] buffer, _ in self?.send(buffer, to: target) }
        do { try e.start() } catch {
            Task { @MainActor in failed("VBAN: couldn't start the microphone (\(error.localizedDescription)).") }
            return
        }
        engine = e
        StreamLog.shared.add("VBAN: sending \(packetizer.channels == 1 ? "mono" : "stereo") \(packetizer.sampleRate) Hz as \"\(packetizer.streamName)\" to \(destination):\(settings.port) from \(input.channelCount)-channel \(Int(input.sampleRate)) Hz input")
        startPacing()
    }

    private func send(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) {
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.floatChannelData?[0] else { return }
        var floats = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * packetizer.channels))
        queue.async { [weak self] in
            guard let self, var proc = self.processor else { return }
            proc.process(&floats)
            let level = proc.takePeak()
            self.processor = proc
            let on = self.transmitting
            let samples: [Int16] = on ? floats.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) } : [Int16](repeating: 0, count: floats.count)
            self.withLock { self._meter = on ? max(level, self._meter * 0.7) : self._meter * 0.5 }
            self.packetizer.append(samples)
            self.peak = max(self.peak, VBANPacketizer.peakDB(samples))
            if Date().timeIntervalSince(self.lastLevelLog) >= 5 {
                StreamLog.shared.add(String(format: "VBAN: microphone peak %.0f dBFS over the last 5 s", self.peak))
                self.peak = -120; self.lastLevelLog = Date()
            }
        }
    }

    /// macOS delivers microphone audio in chunks (often 100 ms); VBAN receivers expect one packet per packet's worth
    /// of time. Send on a steady clock, catching up when behind.
    private func startPacing() {
        let interval = Double(packetizer.samplesPerPacket) / Double(packetizer.sampleRate)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let start = DispatchTime.now()
        var sent = 0
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, let c = self.connection else { return }
            // Packets due by now since the start, so timer jitter doesn't change the rate.
            let due = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 / interval)
            var n = max(1, due - sent)
            if n > 4 { n = 4; sent = due - 1 }           // after a stall, don't flood the receiver
            for _ in 0..<n {
                guard let packet = self.packetizer.nextPacket() else { break }
                c.send(content: packet, completion: .idempotent)
                self.sentPackets += 1
            }
            sent += n
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        connection?.cancel(); connection = nil
        if sentPackets > 0 { StreamLog.shared.add("VBAN: sent \(sentPackets) packets") }
    }

    /// Microphones: (Core Audio unique ID, name).
    static func microphones() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let rc = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return rc == noErr && id != 0 ? id : nil
    }
}
