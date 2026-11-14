// SPDX-License-Identifier: GPL-3.0-only
// One stream at a time (the Moonlight core is single-session): starts the app on the host, connects,
// and routes the core's callbacks to video, audio, controllers and the stream window.
import AppKit
import NokcanduCore
import NokcanduStreamCore

/// What the stream window needs to hear about.
@MainActor protocol StreamConnectionDelegate: AnyObject {
    func streamStage(_ text: String)
    func streamStarted()
    func streamEnded(error: String?)
    func streamPoorConnection(_ poor: Bool)
    func streamRumble(controller: Int, low: UInt16, high: UInt16)
    func streamTriggerRumble(controller: Int, left: UInt16, right: UInt16)
    func streamMotionRequested(controller: Int, type: UInt8, rateHz: UInt16)
    func streamLight(controller: Int, r: UInt8, g: UInt8, b: UInt8)
    func streamHDR(_ on: Bool)
}

final class StreamConnection: @unchecked Sendable {
    /// The running stream, for the C callbacks.
    nonisolated(unsafe) static var current: StreamConnection?

    let video = StreamVideoDecoder()
    let audio = StreamAudioPlayer()
    weak var delegate: StreamConnectionDelegate?
    let profile: StreamProfile
    let host: StreamHost
    let address: String
    private(set) var width = 1920, height = 1080
    private(set) var negotiatedFormat: Int32 = 0
    private var stopping = false
    private(set) var started = false

    init(host: StreamHost, profile: StreamProfile, address: String) {
        self.host = host; self.profile = profile; self.address = address
        video.pacing = profile.video.pacing
        video.frameBuffer = profile.video.frameBuffer
        video.fullRange = profile.video.fullRange
        audio.volume = Float(profile.audio.volume)
        audio.outputDevice = profile.audio.outputDevice
    }

    /// The formats to offer, best first, limited by what the host and this Mac support.
    static func videoFormats(_ v: StreamProfile.Video, hostModes: Int) -> Int32 {
        let h264 = Int32(VIDEO_FORMAT_H264), hevc = Int32(VIDEO_FORMAT_H265), av1 = Int32(VIDEO_FORMAT_AV1_MAIN8)
        let canHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let canAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let hostHEVC = hostModes == 0 || hostModes & 0x180300 != 0      // SCM_MASK_HEVC
        let hostAV1 = hostModes & 0x630000 != 0       // SCM_MASK_AV1
        var f: Int32 = h264
        switch v.codec {
        case .h264: f = h264
        case .hevc: f = h264 | (canHEVC ? hevc : 0)
        case .av1: f = h264 | (canHEVC ? hevc : 0) | (canAV1 ? av1 : 0)
        case .automatic:
            f = h264 | (canHEVC && hostHEVC ? hevc : 0) | (canAV1 && hostAV1 ? av1 : 0)
        }
        if v.hdr {
            if f & hevc != 0 { f |= Int32(VIDEO_FORMAT_H265_MAIN10) }
            if f & av1 != 0 { f |= Int32(VIDEO_FORMAT_AV1_MAIN10) }
        }
        if v.yuv444 {
            f |= Int32(VIDEO_FORMAT_H264_HIGH8_444)
            if f & hevc != 0 { f |= Int32(VIDEO_FORMAT_H265_REXT8_444) | (v.hdr ? Int32(VIDEO_FORMAT_H265_REXT10_444) : 0) }
            if f & av1 != 0 { f |= Int32(VIDEO_FORMAT_AV1_HIGH8_444) | (v.hdr ? Int32(VIDEO_FORMAT_AV1_HIGH10_444) : 0) }
        }
        // With a codec chosen, don't let the host fall back to H.264 unless that's all there is.
        if v.codec == .hevc, f & hevc != 0 { f &= ~Int32(VIDEO_FORMAT_MASK_H264) }
        if v.codec == .av1, f & av1 != 0 { f &= ~(Int32(VIDEO_FORMAT_MASK_H264) | Int32(VIDEO_FORMAT_MASK_H265)) }
        return f
    }

    static func audioConfiguration(_ c: StreamProfile.Audio.Channels) -> Int32 {
        func make(_ count: Int32, _ mask: Int32) -> Int32 { (mask << 16) | (count << 8) | 0xCA }
        switch c {
        case .stereo: return make(2, 0x3)
        case .surround51: return make(6, 0x3F)
        case .surround71: return make(8, 0x63F)
        }
    }

    /// Launches the app and connects. Blocking: call off the main thread. Throws with a message for the user.
    func start(identity: StreamIdentity, size: CGSize, refreshRate: Double, gamepadMask: Int) throws {
        StreamLog.shared.clear()
        let cert = host.serverCertificate.flatMap { Data(base64Encoded: $0) }
        guard cert != nil else { throw StreamError.notPaired }
        let client = StreamClient(address: address, httpPort: host.httpPort, httpsPort: host.httpsPort, identity: identity, serverCertificate: cert)
        report("Asking \(host.name)…")
        let info = try client.serverInfo(timeout: 8)
        if info.certificateRejected { throw StreamError.pairing("\(host.name) no longer accepts this Mac. Pair with it again (its pairings may have been reset).") }
        guard let appID = profile.appID else { throw StreamError.host("Choose an app for this stream first.") }

        let v = profile.video
        width = v.width ?? max(640, Int(size.width) / 2 * 2)
        height = v.height ?? max(360, Int(size.height) / 2 * 2)
        let fps = v.fps
        let bitrate = v.bitrateKbps ?? StreamProfile.Video.defaultBitrate(width: width, height: height, fps: fps, yuv444: v.yuv444)
        let formats = Self.videoFormats(v, hostModes: info.codecModes)
        let remote = profile.route.isRemote || !StreamAddress.isPrivate(address)

        var riKey = (try? StreamClient.randomData(16)) ?? Data(count: 16)
        if riKey.count != 16 { riKey = Data(count: 16) }
        let riKeyID = Int32.random(in: 0...Int32.max)
        let resume = info.currentGame != 0 && info.currentGame == appID
        if info.currentGame != 0 && info.currentGame != appID {
            report("Quitting the app already running on \(host.name)…")
            try client.quit()
        }
        report(resume ? "Resuming \(profile.appName ?? "the app")…" : "Starting \(profile.appName ?? "the app")…")
        let session = try client.launch(.init(appID: appID, width: width, height: height, fps: fps, optimizeGameSettings: profile.optimizeGameSettings,
                                              riKey: riKey, riKeyID: riKeyID, hdr: v.hdr && formats & Int32(VIDEO_FORMAT_MASK_10BIT) != 0,
                                              playAudioOnHost: profile.audio.playOnHost,
                                              surroundAudioInfo: Int(Self.surroundInfo(Self.audioConfiguration(profile.audio.channels))),
                                              gamepadMask: gamepadMask, multiController: profile.controller.multipleControllers, resume: resume),
                                       isSunshine: host.capabilities.isSunshine || info.appVersion.split(separator: ".").last?.hasPrefix("-") == true)

        var server = SERVER_INFORMATION()
        LiInitializeServerInformation(&server)
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(width); config.height = Int32(height); config.fps = Int32(fps)
        config.bitrate = Int32(bitrate)
        config.supportedVideoFormats = formats
        config.audioConfiguration = Self.audioConfiguration(profile.audio.channels)
        config.colorRange = v.fullRange ? 1 : 0
        config.colorSpace = 1      // BT.709 for SDR; the host switches to BT.2020 for HDR
        config.clientRefreshRateX100 = Int32(refreshRate * 100)
        config.encryptionFlags = Int32(bitPattern: 0xFFFFFFFF)   // ENCFLG_ALL
        config.redirectMic = false            // microphone sending isn't built yet
        config.streamingRemotely = remote ? 1 : 2                // STREAM_CFG_REMOTE : STREAM_CFG_AUTO
        config.packetSize = remote ? 1024 : 1392
        riKey.withUnsafeBytes { b in withUnsafeMutableBytes(of: &config.remoteInputAesKey) { $0.copyMemory(from: b) } }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { iv in
            iv.initializeMemory(as: UInt8.self, repeating: 0)
            var id = riKeyID.bigEndian
            withUnsafeBytes(of: &id) { iv.copyMemory(from: $0) }
        }

        var dr = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&dr)
        dr.setup = { format, w, h, rate, _, _ in StreamConnection.current?.videoSetup(format, w, h, rate) ?? -1 }
        dr.cleanup = { StreamConnection.current?.video.cleanup() }
        dr.submitDecodeUnit = { du in StreamConnection.current.map { $0.video.submit(du!) } ?? DR_OK }
        dr.capabilities = Int32(CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC | CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1)

        var ar = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&ar)
        ar.`init` = { cfg, opus, _, _ in StreamConnection.current?.audio.setup(audioConfiguration: cfg, opus: opus!.pointee) ?? -1 }
        ar.cleanup = { StreamConnection.current?.audio.cleanup() }
        ar.decodeAndPlaySample = { data, len in StreamConnection.current?.audio.play(data, length: len) }
        ar.capabilities = Int32(CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION)

        var cl = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&cl)
        nk_set_log_handler { line in if let line { StreamLog.shared.add(String(cString: line).trimmingCharacters(in: .newlines)) } }
        nk_install_log(&cl)
        cl.stageStarting = { stage in
            let name = String(cString: LiGetStageName(stage))
            StreamConnection.current?.report("Connecting: \(name)…")
        }
        cl.stageFailed = { stage, code in
            StreamLog.shared.add("Stage \(String(cString: LiGetStageName(stage))) failed (\(code))")
        }
        cl.connectionStarted = { StreamConnection.current?.connected() }
        cl.connectionTerminated = { code in StreamConnection.current?.terminated(code) }
        cl.connectionStatusUpdate = { status in
            let poor = status == CONN_STATUS_POOR
            DispatchQueue.main.async { StreamConnection.current?.delegate?.streamPoorConnection(poor) }
        }
        cl.rumble = { n, low, high in DispatchQueue.main.async { StreamConnection.current?.delegate?.streamRumble(controller: Int(n), low: low, high: high) } }
        cl.rumbleTriggers = { n, l, r in DispatchQueue.main.async { StreamConnection.current?.delegate?.streamTriggerRumble(controller: Int(n), left: l, right: r) } }
        cl.setMotionEventState = { n, type, rate in DispatchQueue.main.async { StreamConnection.current?.delegate?.streamMotionRequested(controller: Int(n), type: type, rateHz: rate) } }
        cl.setControllerLED = { n, r, g, b in DispatchQueue.main.async { StreamConnection.current?.delegate?.streamLight(controller: Int(n), r: r, g: g, b: b) } }
        cl.setHdrMode = { on in DispatchQueue.main.async { StreamConnection.current?.delegate?.streamHDR(on) } }

        report("Connecting…")
        let rc: Int32 = address.withCString { addr in
            info.appVersion.withCString { appVersion in
                info.gfeVersion.withCString { gfe in
                    (session ?? "").withCString { rtsp in
                        server.address = addr
                        server.serverInfoAppVersion = appVersion
                        server.serverInfoGfeVersion = gfe
                        server.rtspSessionUrl = session == nil ? nil : rtsp
                        server.serverCodecModeSupport = Int32(info.codecModes)
                        return LiStartConnection(&server, &config, &cl, &dr, &ar, nil, 0, nil, 0)
                    }
                }
            }
        }
        if rc != 0 {
            let last = StreamLog.shared.text.split(separator: "\n").last.map(String.init) ?? ""
            throw StreamError.host("Couldn't connect to \(host.name)\(last.isEmpty ? "." : ": \(last)")")
        }
        negotiatedFormat = formats
    }

    private func videoSetup(_ format: Int32, _ w: Int32, _ h: Int32, _ rate: Int32) -> Int32 {
        negotiatedFormat = format
        StreamLog.shared.add("Video: \(Self.formatName(format)) \(w)×\(h) at \(rate) fps")
        return video.setup(videoFormat: format, width: w, height: h, fps: rate)
    }

    static func formatName(_ f: Int32) -> String {
        let ten = f & Int32(VIDEO_FORMAT_MASK_10BIT) != 0 ? " 10-bit" : ""
        let yuv = f & Int32(VIDEO_FORMAT_MASK_YUV444) != 0 ? " 4:4:4" : ""
        if f & Int32(VIDEO_FORMAT_MASK_AV1) != 0 { return "AV1\(ten)\(yuv)" }
        if f & Int32(VIDEO_FORMAT_MASK_H265) != 0 { return "HEVC\(ten)\(yuv)" }
        return "H.264\(yuv)"
    }

    static func surroundInfo(_ cfg: Int32) -> Int32 {
        let mask = (cfg >> 16) & 0xFFFF, count = (cfg >> 8) & 0xFF
        return mask << 16 | count
    }

    private func report(_ s: String) {
        StreamLog.shared.add(s)
        DispatchQueue.main.async { [weak self] in self?.delegate?.streamStage(s) }
    }
    private func connected() {
        started = true
        DispatchQueue.main.async { [weak self] in self?.delegate?.streamStarted() }
    }
    private func terminated(_ code: Int32) {
        let message: String?
        switch code {
        case 0: message = nil                                     // ML_ERROR_GRACEFUL_TERMINATION
        case -100: message = "The host stopped sending video. Check its network connection, or try a lower bitrate."   // NO_VIDEO_TRAFFIC
        case -101: message = "The host stopped sending video frames."
        case -102: message = "The host ended the stream unexpectedly."
        case -103: message = "The host stopped the stream because something on its screen is protected content."
        case -104: message = "This Mac couldn't decode the stream. Try another codec in the stream's settings."
        case -105, -106: message = "The connection to \(host.name) was lost."
        default: message = "The connection to \(host.name) was lost (\(code))."
        }
        DispatchQueue.global().async { [weak self] in
            // LiStopConnection can't run on the core's own thread.
            self?.stop()
            DispatchQueue.main.async { self?.delegate?.streamEnded(error: message) }
        }
    }

    /// Ends the stream (the app keeps running on the host). Blocking.
    func stop() {
        guard !stopping else { return }
        stopping = true
        LiStopConnection()
    }

    /// Ends the stream and quits the app on the host.
    func stopAndQuit(identity: StreamIdentity) {
        stop()
        let cert = host.serverCertificate.flatMap { Data(base64Encoded: $0) }
        let client = StreamClient(address: address, httpPort: host.httpPort, httpsPort: host.httpsPort, identity: identity, serverCertificate: cert)
        try? client.quit()
    }
}

import VideoToolbox
