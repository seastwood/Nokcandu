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
    /// Capture state, owned by `queue`: the engine is rebuilt whenever macOS stops it (see restartCapture).
    private var configObserver: NSObjectProtocol?
    private var captureFormat: AVAudioFormat?
    private var lastBuffer = Date(), lastRestart = Date.distantPast
    private var watchdog: DispatchSourceTimer?
    private var stopped = false, outageReported = false
    private var notify: (@MainActor (String) -> Void)?
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
        notify = failed
        processor = VBANProcessor(settings: settings, sampleRate: Double(packetizer.sampleRate), channels: packetizer.channels)
        let problem = queue.sync { startCapture() }
        if let problem {
            Task { @MainActor in failed(problem) }
            return
        }
        if let f = captureFormat {
            StreamLog.shared.add("VBAN: sending \(packetizer.channels == 1 ? "mono" : "stereo") \(packetizer.sampleRate) Hz as \"\(packetizer.streamName)\" to \(destination):\(settings.port) from \(f.channelCount)-channel \(Int(f.sampleRate)) Hz input")
        }
        startPacing()
        startWatchdog()
    }

    /// Builds a fresh engine on the microphone as it is now and starts it. On `queue`. Returns what went wrong, or nil.
    private func startCapture() -> String? {
        let e = AVAudioEngine()
        if let uid = settings.inputDevice, let id = Self.deviceID(uid: uid), let unit = e.inputNode.audioUnit {
            var dev = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = e.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(packetizer.sampleRate), channels: AVAudioChannelCount(packetizer.channels), interleaved: true),
              let conv = AVAudioConverter(from: input, to: target) else {
            return "VBAN: the microphone isn't available."
        }
        // Each engine's tap has its own converter: the input's sample rate can differ after a restart.
        e.inputNode.installTap(onBus: 0, bufferSize: 512, format: input) { [weak self] buffer, _ in self?.send(buffer, with: conv, to: target) }
        do { try e.start() } catch {
            e.inputNode.removeTap(onBus: 0)
            return "VBAN: couldn't start the microphone (\(error.localizedDescription))."
        }
        engine = e
        captureFormat = input
        lastBuffer = Date()
        // macOS stops an engine when the audio setup changes (headphones or AirPods connecting, the default device
        // switched, a sample rate change). Without this the microphone went silent until VBAN was switched off and on.
        let id = ObjectIdentifier(e)
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            // Not from inside the notification: the engine can't be torn down there. A moment later, so a burst of
            // changes (a device connecting posts several) settles into one restart.
            self?.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let e = self.engine, ObjectIdentifier(e) == id else { return }
                let now = e.inputNode.outputFormat(forBus: 0)
                // Still running on the same input: nothing was lost (the stream's sound restarting posts this too).
                if e.isRunning, let was = self.captureFormat, now.sampleRate == was.sampleRate, now.channelCount == was.channelCount { return }
                self.restartCapture(reason: "the Mac's audio setup changed")
            }
        }
        return nil
    }

    private func stopCapture() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
    }

    /// Starts the microphone again after macOS stopped it. On `queue`.
    private func restartCapture(reason: String) {
        guard !stopped, Date().timeIntervalSince(lastRestart) >= 1 else { return }
        lastRestart = Date()
        stopCapture()
        if let problem = startCapture() {
            // The watchdog tries again every few seconds; say so once, not on every attempt.
            if !outageReported {
                outageReported = true
                StreamLog.shared.add("VBAN: microphone stopped (\(reason)) and couldn't restart: \(problem) Trying again every few seconds.")
                if let notify { Task { @MainActor in notify("The VBAN microphone stopped. Trying to start it again…") } }
            }
            return
        }
        let f = captureFormat
        StreamLog.shared.add("VBAN: microphone restarted (\(reason)); \(f?.channelCount ?? 0)-channel \(Int(f?.sampleRate ?? 0)) Hz input")
        if outageReported, let notify { Task { @MainActor in notify("The VBAN microphone is sending again.") } }
        outageReported = false
    }

    /// Whatever stopped the microphone, notice it: no audio from it for 3 seconds means it needs starting again
    /// (a running microphone always delivers, even silence).
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped, Date().timeIntervalSince(self.lastBuffer) >= 3 else { return }
            self.restartCapture(reason: "no audio from the microphone for 3 seconds")
        }
        t.resume()
        watchdog = t
    }

    private func send(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) {
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
            self.lastBuffer = Date()
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
        queue.sync {
            stopped = true
            watchdog?.cancel(); watchdog = nil
            stopCapture()
        }
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
