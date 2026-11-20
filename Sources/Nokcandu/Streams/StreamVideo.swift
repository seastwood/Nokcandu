// SPDX-License-Identifier: GPL-3.0-only
// Decodes the host's video with VideoToolbox (hardware H.264, HEVC and AV1) and shows it on an
// AVSampleBufferDisplayLayer, paced to the display. Follows Moonlight's VideoDecoderRenderer.
import AVFoundation
import CoreMedia
import CoreVideo
import NokcanduCore
import NokcanduStreamCore
import QuartzCore
import VideoToolbox
import os

final class StreamVideoDecoder: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    /// The decoder's own state (session, format), used only on Moonlight's decoder thread and in setup/cleanup.
    /// VideoToolbox's output handler and the display refresh never take it: DecodeFrame can block until
    /// finished frames are handed out, so a handler waiting for this lock froze the stream and the main thread.
    private let lock = NSLock()
    /// Finished frames and the "needs a key frame" flag, shared with the output handler and the display refresh.
    private var frameLock = os_unfair_lock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var videoFormat: Int32 = 0
    private var parameterSets: [Data] = []
    private(set) var width = 0, height = 0, fps = 60
    var pacing: StreamProfile.Video.Pacing = .balanced
    /// Frames held before showing; nil follows the pacing. 0 shows each frame as soon as it's decoded.
    var frameBuffer: Int?
    private var buffered: Int { frameBuffer ?? Self.defaultBuffer(pacing) }
    static func defaultBuffer(_ p: StreamProfile.Video.Pacing) -> Int { switch p { case .lowestLatency: 0; case .balanced: 1; case .smoothest: 2 } }
    var fullRange = false
    /// The host's HDR metadata while HDR is on (`setHDR`), attached to every frame shown. Guarded by `frameLock`.
    private var hdrMetadata: StreamHDRMetadata?
    private var currentHDR: StreamHDRMetadata? { os_unfair_lock_lock(&frameLock); defer { os_unfair_lock_unlock(&frameLock) }; return hdrMetadata }
    /// Decoded frames waiting for the display's next refresh (balanced and smoothest pacing), with when each
    /// was decoded and when its first packet arrived.
    private var pending: [CVPixelBuffer] = []
    private var receipts: [CFTimeInterval?] = []
    /// Draws frames with Metal instead of the display layer while set (`useRenderer`). Guarded by `frameLock`.
    private var metal: StreamMetalRenderer?
    /// The display's refresh timing (main thread), for estimating when the display layer shows a frame.
    private var lastVsync: CFTimeInterval = 0, refreshInterval: CFTimeInterval = 1.0 / 60
    let stats = StreamVideoStats()
    /// Asked for a key frame since the last decode error.
    private var needsIDR = false
    /// Decoding failing without a single good frame since `failingSince`: past `giveUpAfter` seconds the stream
    /// ends with a message (`onUndecodable`) instead of asking the host for key frames forever. Every rejected
    /// frame asked the host for a new one, many times a second, which left a host (Apollo) needing a restart.
    private var failingSince: Double?, lastKeyFrameAsk = 0.0, gaveUp = false
    static let giveUpAfter = 5.0, keyFrameAskInterval = 0.25
    var onUndecodable: (() -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Keep the newest frame on screen rather than a backlog.
        layer.preventsDisplaySleepDuringVideoPlayback = true
    }

    // MARK: Moonlight callbacks (its decoder thread)

    func setup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        self.videoFormat = videoFormat
        self.width = Int(width); self.height = Int(height); self.fps = Int(fps)
        os_unfair_lock_lock(&frameLock); failingSince = nil; gaveUp = false; lastKeyFrameAsk = 0; decodeFailures = [:]; os_unfair_lock_unlock(&frameLock)
        invalidate()
        return 0
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        invalidate()
        os_unfair_lock_lock(&frameLock); pending.removeAll(); arrivals.removeAll(); receipts.removeAll(); os_unfair_lock_unlock(&frameLock)
        DispatchQueue.main.async { [layer] in layer.flushAndRemoveImage() }
    }

    private func invalidate() {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil; parameterSets = []
    }

    private var isAV1: Bool { videoFormat & Int32(VIDEO_FORMAT_MASK_AV1) != 0 }
    private var isHEVC: Bool { videoFormat & Int32(VIDEO_FORMAT_MASK_H265) != 0 }

    /// One frame from the host: Annex B NAL units for H.264/HEVC (parameter sets in their own entries on key
    /// frames), or an AV1 temporal unit.
    func submit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        let unit = du.pointee
        stats.received(unit)
        // Given up: drop frames quietly until the stream ends, rather than asking the host for key frames.
        if hasGivenUp { return DR_OK }
        lock.lock(); defer { lock.unlock() }
        // The picture data goes straight into the block buffer the decoder reads: one copy. (It was copied
        // three times: into a joined buffer, a converted one, and the decoder's.) H.264/HEVC start codes are
        // then turned into lengths in place; only 3-byte start codes, which need room, take a second buffer.
        var sets: [Data] = []
        var total = 0
        var entry = unit.bufferList
        while let e = entry {
            let n = Int(e.pointee.length)
            if isAV1 || e.pointee.bufferType == BUFFER_TYPE_PICDATA { total += n }
            else { sets.append(Self.stripStartCode(Data(bytes: e.pointee.data, count: n))) }
            entry = e.pointee.next
        }
        guard total > 0, var block = Self.makeBlock(length: total), let base = Self.pointer(block) else { return DR_OK }
        var offset = 0
        entry = unit.bufferList
        while let e = entry {
            let n = Int(e.pointee.length)
            if isAV1 || e.pointee.bufferType == BUFFER_TYPE_PICDATA { memcpy(base + offset, e.pointee.data, n); offset += n }
            entry = e.pointee.next
        }
        var length = total
        if !isAV1, !Self.lengthPrefixInPlace(base, count: total) {
            var converted = Data(capacity: total + 64)
            Self.appendLengthPrefixed(Data(bytesNoCopy: base, count: total, deallocator: .none), to: &converted)
            guard let b = Self.makeBlock(length: converted.count), let p = Self.pointer(b) else { return DR_OK }
            converted.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: converted.count)
            block = b; length = converted.count
        }
        if unit.frameType == FRAME_TYPE_IDR {
            if isAV1 {
                if !makeAV1Format(Data(bytes: base, count: total)) { return DR_NEED_IDR }
            } else if !sets.isEmpty, sets != parameterSets {
                if !makeFormat(sets) { return DR_NEED_IDR }
            }
            setNeedsIDR(false)
        }
        if needsKeyFrame { return DR_NEED_IDR }
        guard let format else { return DR_OK }
        if session == nil, !makeSession(format) { return DR_NEED_IDR }
        guard let sample = Self.sampleBuffer(block, length: length, format: format) else { return DR_OK }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let decodeStarted = LiGetMicroseconds()
        // The frame's first packet, on CACurrentMediaTime's clock (the core counts from its own start on the same clock).
        let receivedAt: CFTimeInterval? = unit.receiveTimeUs > 0 ? CACurrentMediaTime() - Double(decodeStarted - min(decodeStarted, unit.receiveTimeUs)) / 1_000_000 : nil
        let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.stats.dropped()
                if status != noErr { self.noteDecodeFailure(status); self.setNeedsIDR(true); if self.mayAskForKeyFrame() { LiRequestIdrFrame() } }
                return
            }
            self.decodedOne()
            self.stats.decoded(startedUs: decodeStarted)
            self.show(image, receivedAt: receivedAt)
        }
        if status != noErr {
            noteDecodeFailure(status)
            // The session can be lost (sleep, display change): start again from the next key frame.
            if status == kVTInvalidSessionErr { invalidate() }
            setNeedsIDR(true)
            return DR_NEED_IDR
        }
        return DR_OK
    }

    /// Decode failures in the stream log: the first few of each kind, so a codec this Mac rejects says why
    /// instead of only showing a black picture.
    private var decodeFailures: [OSStatus: Int] = [:]
    private func noteDecodeFailure(_ status: OSStatus) {
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(&frameLock)
        let n = (decodeFailures[status] ?? 0) + 1; decodeFailures[status] = n
        if failingSince == nil { failingSince = now }
        let giveUp = !gaveUp && now - failingSince! >= Self.giveUpAfter
        if giveUp { gaveUp = true }
        os_unfair_lock_unlock(&frameLock)
        if n <= 3 || n % 500 == 0 { StreamLog.shared.add("Video: the decoder rejected a frame (\(status)), \(n) so far") }
        if giveUp {
            StreamLog.shared.add("Video: no frame decoded for \(Int(Self.giveUpAfter)) s (\(status)); ending the stream")
            DispatchQueue.main.async { [weak self] in self?.onUndecodable?() }
        }
    }
    private func decodedOne() { os_unfair_lock_lock(&frameLock); failingSince = nil; os_unfair_lock_unlock(&frameLock) }
    /// At most one key-frame request of ours every `keyFrameAskInterval`, and none once given up.
    private func mayAskForKeyFrame() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(&frameLock); defer { os_unfair_lock_unlock(&frameLock) }
        guard !gaveUp, now - lastKeyFrameAsk >= Self.keyFrameAskInterval else { return false }
        lastKeyFrameAsk = now; return true
    }
    private var hasGivenUp: Bool { os_unfair_lock_lock(&frameLock); defer { os_unfair_lock_unlock(&frameLock) }; return gaveUp }
    private func setNeedsIDR(_ v: Bool) { os_unfair_lock_lock(&frameLock); needsIDR = v; os_unfair_lock_unlock(&frameLock) }
    private var needsKeyFrame: Bool { os_unfair_lock_lock(&frameLock); defer { os_unfair_lock_unlock(&frameLock) }; return needsIDR }

    // MARK: Showing frames

    private func show(_ image: CVPixelBuffer, receivedAt: CFTimeInterval?) {
        let keep = buffered
        let decodedAt = CACurrentMediaTime()
        // 0: show each frame the moment it's decoded.
        guard keep > 0 else { enqueue(image, decodedAt: decodedAt, receivedAt: receivedAt); return }
        // Otherwise hold up to `keep` frames for the display's refreshes; the oldest beyond that are dropped.
        os_unfair_lock_lock(&frameLock)
        pending.append(image)
        arrivals.append(decodedAt)
        receipts.append(receivedAt)
        let extra = pending.count - keep
        if extra > 0 { pending.removeFirst(extra); arrivals.removeFirst(extra); receipts.removeFirst(extra) }
        let depth = pending.count
        os_unfair_lock_unlock(&frameLock)
        stats.telemetry.buffer(depth: depth)
        if extra > 0 { stats.paced(dropped: extra) }
    }
    private var arrivals: [CFTimeInterval] = []

    /// Called on each display refresh.
    func displayRefresh(timestamp: CFTimeInterval? = nil, duration: CFTimeInterval? = nil) {
        if let timestamp, let duration, duration > 0 { lastVsync = timestamp; refreshInterval = duration }
        let keep = buffered
        let now = CACurrentMediaTime(), frameTime = 1 / Double(max(30, fps))
        stats.telemetry.displayTick(at: now)
        os_unfair_lock_lock(&frameLock)
        var next: CVPixelBuffer?
        var decodedAt = now
        var receivedAt: CFTimeInterval?
        // Show the oldest frame once the buffer is full, or once it has waited its buffer time (a still desktop
        // sends few frames; don't hold the last one back).
        if !pending.isEmpty, pending.count >= keep || now - (arrivals.first ?? now) > Double(keep) * frameTime * 1.5 {
            next = pending.removeFirst(); decodedAt = arrivals.removeFirst(); receivedAt = receipts.removeFirst()
        }
        os_unfair_lock_unlock(&frameLock)
        if let next { enqueue(next, decodedAt: decodedAt, receivedAt: receivedAt) }
    }

    /// The display layer can't say when a frame reached the screen. Estimate (main thread): the first display
    /// refresh after it was handed over, plus one refresh for the window server to put it on the display.
    private func estimateOnScreen(decodedAt: CFTimeInterval, receivedAt: CFTimeInterval?) {
        let now = CACurrentMediaTime(), interval = refreshInterval
        guard lastVsync > 0, interval > 0 else { return }
        let next = lastVsync + (max(0, (now - lastVsync) / interval).rounded(.up)) * interval
        let shown = max(next, now) + interval
        stats.telemetry.onScreen(decodeToScreenMs: (shown - decodedAt) * 1000, receiveToScreenMs: receivedAt.map { (shown - $0) * 1000 }, measured: false)
    }

    // MARK: Renderer

    /// Main thread. Switches what draws the picture; returns the layer to show and, when Metal was asked for but
    /// can't be used here, why (the display layer is used instead). `onMetalFailure` runs on the main thread if
    /// Metal gives up during the stream.
    func useRenderer(_ r: StreamProfile.Video.Renderer, vsync: Bool, onMetalFailure: @escaping (String) -> Void) -> (layer: CALayer, problem: String?) {
        os_unfair_lock_lock(&frameLock); let current = metal; os_unfair_lock_unlock(&frameLock)
        guard r == .metal else {
            if current != nil {
                os_unfair_lock_lock(&frameLock); metal = nil; os_unfair_lock_unlock(&frameLock)
                StreamLog.shared.add("Video: drawing with the display layer")
                LiRequestIdrFrame()       // the host sends frames only when the picture changes: repaint now
            }
            return (layer, nil)
        }
        if let current { current.vsync = vsync; return (current.layer, nil) }
        let (made, why) = StreamMetalRenderer.make(vsync: vsync)
        guard let m = made else {
            StreamLog.shared.add("Video: Metal isn't available (\(why ?? "unknown")); drawing with the display layer")
            return (layer, why ?? "Metal isn't available")
        }
        let telemetry = stats.telemetry
        m.onDrawn = { f in telemetry.enqueued(waitMs: (CACurrentMediaTime() - f.decodedAt) * 1000, at: CACurrentMediaTime()) }
        m.onScreen = { f, at in
            telemetry.onScreen(decodeToScreenMs: (at - f.decodedAt) * 1000, receiveToScreenMs: f.receivedAt.map { (at - $0) * 1000 }, measured: true)
        }
        m.onReplaced = { telemetry.paced(dropped: 1) }
        m.onFailure = { [weak self, weak m] why in
            DispatchQueue.main.async {
                guard let self else { return }
                os_unfair_lock_lock(&self.frameLock); if let m, self.metal === m { self.metal = nil }; os_unfair_lock_unlock(&self.frameLock)
                LiRequestIdrFrame()
                onMetalFailure(why)
            }
        }
        m.setHDR(currentHDR)
        os_unfair_lock_lock(&frameLock); metal = m; os_unfair_lock_unlock(&frameLock)
        StreamLog.shared.add("Video: drawing with Metal on \(m.deviceName), V-sync \(vsync ? "on" : "off")")
        LiRequestIdrFrame()
        return (m.layer, nil)
    }

    /// The Metal renderer in use, if any (main thread: to size its layer).
    var metalRenderer: StreamMetalRenderer? { os_unfair_lock_lock(&frameLock); defer { os_unfair_lock_unlock(&frameLock) }; return metal }

    /// HDR switched on or off by the host (main thread). With it on, the host's mastering-display and
    /// content-light metadata go on every frame, as Moonlight PC 6.2.0 does, so macOS shows HDR at the
    /// brightness it was made for and tonemaps it on a display with less range.
    func setHDR(_ on: Bool) {
        let md = on ? StreamHDRMetadata.current() : nil
        os_unfair_lock_lock(&frameLock); hdrMetadata = md; let metal = self.metal; os_unfair_lock_unlock(&frameLock)
        metal?.setHDR(md)
        if on {
            StreamLog.shared.add("Video: HDR metadata from the host: \(md == nil ? "none" : [md!.masteringDisplayColorVolume != nil ? "mastering display" : nil, md!.contentLightLevelInfo != nil ? "content light level" : nil].compactMap { $0 }.joined(separator: " and "))")
        }
    }

    /// HDR frames: the host's metadata, and a CGColorSpace for PQ and HLG (Moonlight found external displays
    /// need it to show HDR properly). SDR frames are left as VideoToolbox made them.
    private func attachHDR(_ image: CVPixelBuffer) {
        guard let transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String else { return }
        let space: CFString
        if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { space = CGColorSpace.itur_2100_PQ }
        else if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { space = CGColorSpace.itur_2100_HLG }
        else { return }
        os_unfair_lock_lock(&frameLock); let md = hdrMetadata; os_unfair_lock_unlock(&frameLock)
        if let cs = CGColorSpace(name: space) { CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate) }
        if let d = md?.masteringDisplayColorVolume { CVBufferSetAttachment(image, kCVImageBufferMasteringDisplayColorVolumeKey, d as CFData, .shouldPropagate) }
        if let d = md?.contentLightLevelInfo { CVBufferSetAttachment(image, kCVImageBufferContentLightLevelInfoKey, d as CFData, .shouldPropagate) }
    }

    private func enqueue(_ image: CVPixelBuffer, decodedAt: CFTimeInterval, receivedAt: CFTimeInterval?) {
        os_unfair_lock_lock(&frameLock); let metal = self.metal; os_unfair_lock_unlock(&frameLock)
        if let metal { metal.submit(.init(image: image, receivedAt: receivedAt, decodedAt: decodedAt)); return }
        attachHDR(image)
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &desc)
        guard let desc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let a = attachments.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let layer = self.layer
        // On a display refresh (the main thread) the frame goes up at once; it went round the main queue
        // again first, a turn later. Straight from the decoder ("Lowest latency"), it goes over to the main thread.
        if Thread.isMainThread {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
            stats.telemetry.enqueued(waitMs: (CACurrentMediaTime() - decodedAt) * 1000, at: CACurrentMediaTime())
            estimateOnScreen(decodedAt: decodedAt, receivedAt: receivedAt)
        } else {
            DispatchQueue.main.async { [stats, weak self] in
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
                stats.telemetry.enqueued(waitMs: (CACurrentMediaTime() - decodedAt) * 1000, at: CACurrentMediaTime())
                self?.estimateOnScreen(decodedAt: decodedAt, receivedAt: receivedAt)
            }
        }
    }

    // MARK: Format descriptions and the decoder

    private func makeFormat(_ sets: [Data]) -> Bool {
        var desc: CMFormatDescription?
        let pointers = sets.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count); d.copyBytes(to: p, count: d.count); return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = sets.map(\.count)
        let status: OSStatus
        if isHEVC {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { StreamLog.shared.add("Video: couldn't read the stream's parameter sets (\(status))"); return false }
        replaceFormat(desc)
        parameterSets = sets
        let d = CMVideoFormatDescriptionGetDimensions(desc)
        StreamLog.shared.add("Video: \(isHEVC ? "HEVC" : "H.264") parameter sets read (\(sets.count): \(sets.map { String($0.count) }.joined(separator: ", ")) bytes; first bytes \(sets.map { $0.prefix(2).map { String(format: "%02x", $0) }.joined() }.joined(separator: " "))), \(d.width)×\(d.height)")
        return true
    }

    private func makeAV1Format(_ frame: Data) -> Bool {
        var seq = nk_av1_sequence()
        let rc = frame.withUnsafeBytes { nk_av1_parse($0.bindMemory(to: UInt8.self).baseAddress, frame.count, &seq) }
        guard rc == 0 else { return format != nil }      // no sequence header in this frame: keep the one we have
        let av1c = withUnsafeBytes(of: seq.av1c) { Data($0.prefix(seq.av1cLength)) }
        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_FormatName: "av01",
            kCMFormatDescriptionExtension_Depth: 24,
            kCMFormatDescriptionExtension_FullRangeVideo: seq.fullRange == 1,
            kCMFormatDescriptionExtension_FieldCount: 1,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": av1c],
            "BitsPerComponent" as CFString: Int(seq.bitDepth),
        ]
        switch seq.colorPrimaries {
        case 1: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 6: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_SMPTE_C
        case 9: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: break
        }
        switch seq.transferCharacteristics {
        case 1, 6: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 14, 15: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2020
        case 16: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 17: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: break
        }
        switch seq.matrixCoefficients {
        case 1: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 6: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case 9: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: break
        }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: seq.width, height: seq.height,
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { StreamLog.shared.add("Video: couldn't describe the AV1 stream (\(status))"); return false }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: desc) { return true }
        replaceFormat(desc)
        return true
    }

    private func replaceFormat(_ desc: CMVideoFormatDescription) {
        if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: desc) { format = desc; return }
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil
        format = desc
    }

    private func makeSession(_ desc: CMVideoFormatDescription) -> Bool {
        let tenBit = videoFormat & Int32(VIDEO_FORMAT_MASK_10BIT) != 0
        let yuv444 = videoFormat & Int32(VIDEO_FORMAT_MASK_YUV444) != 0
        // The range the stream actually uses (its VUI or AV1 sequence header), not the one asked for: a host
        // resuming an app keeps the session's earlier range, and reading limited-range video as full range
        // washes the picture out (seen November 19, after full range became the default).
        let streamFull = (CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool)
        let fullRange = streamFull ?? self.fullRange
        if let streamFull, streamFull != self.fullRange {
            StreamLog.shared.add("Video: the host sends \(streamFull ? "full" : "limited")-range colour though \(self.fullRange ? "full" : "limited") was asked for (a resumed app keeps the range it started with); showing it as sent")
        }
        let pixel: OSType
        switch (tenBit, yuv444, fullRange) {
        // 10-bit (HDR) follows the colour range too: it was always video range, so a full-range 10-bit stream
        // was decoded into a buffer labelled for the narrower range.
        case (true, true, true): pixel = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case (true, true, false): pixel = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case (true, false, true): pixel = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (true, false, false): pixel = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, true, true): pixel = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case (false, true, false): pixel = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (false, false, true): pixel = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (false, false, false): pixel = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixel,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else {
            StreamLog.shared.add("Video: this Mac can't decode the stream (\(status)). Try another codec in the stream's settings.")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        session = s
        return true
    }

    // MARK: Bitstream helpers

    /// Drops the 3- or 4-byte Annex B start code.
    static func stripStartCode(_ d: Data) -> Data {
        let b = [UInt8](d.prefix(4))
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0, b[3] == 1 { return Data(d.dropFirst(4)) }
        if b.count >= 3, b[0] == 0, b[1] == 0, b[2] == 1 { return Data(d.dropFirst(3)) }
        return Data(d)
    }

    /// Converts Annex B NAL units (one or several in the buffer) to 4-byte length-prefixed form.
    static func appendLengthPrefixed(_ d: Data, to out: inout Data) {
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var starts: [(code: Int, nal: Int)] = []
            var i = 0
            while i + 2 < n {
                if p[i] == 0, p[i + 1] == 0 {
                    if p[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                    if i + 3 < n, p[i + 2] == 0, p[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
                }
                i += 1
            }
            if starts.isEmpty { starts = [(0, 0)] }
            for (k, s) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1].code : n
                let len = end - s.nal
                guard len > 0 else { continue }
                var be = UInt32(len).bigEndian
                withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
                out.append(p.baseAddress! + s.nal, count: len)
            }
        }
    }

    static func makeBlock(length: Int) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr
        else { return nil }
        return block
    }
    static func pointer(_ block: CMBlockBuffer) -> UnsafeMutableRawPointer? {
        var p: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &p) == noErr else { return nil }
        return p.map { UnsafeMutableRawPointer($0) }
    }
    /// Annex B with 4-byte start codes (what hosts send) to 4-byte lengths, in place. False, untouched, if the
    /// data doesn't begin with a start code or has a 3-byte one (which needs a byte more room).
    static func lengthPrefixInPlace(_ raw: UnsafeMutableRawPointer, count n: Int) -> Bool {
        let p = raw.assumingMemoryBound(to: UInt8.self)
        var starts: [Int] = []
        var i = 0
        while i + 3 < n {
            if p[i] == 0, p[i + 1] == 0 {
                if p[i + 2] == 1 { return false }
                if p[i + 2] == 0, p[i + 3] == 1 { starts.append(i); i += 4; continue }
            }
            i += 1
        }
        guard starts.first == 0 else { return false }
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : n
            let len = UInt32(end - s - 4).bigEndian
            _ = withUnsafeBytes(of: len) { memcpy(p + s, $0.baseAddress!, 4) }
        }
        return true
    }
    static func sampleBuffer(_ block: CMBlockBuffer, length: Int, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// Transport metadata converted into bounded, testable interval measurements.
final class StreamVideoStats: @unchecked Sendable {
    let telemetry = StreamTelemetry(at: CACurrentMediaTime())
    func received(_ du: DECODE_UNIT) {
        let now = LiGetMicroseconds()
        telemetry.receive(frame: UInt32(bitPattern: du.frameNumber), bytes: Int(du.fullLength),
                          hostLatencyTenthsMs: du.frameHostProcessingLatency,
                          assemblyMs: du.enqueueTimeUs >= du.receiveTimeUs ? Double(du.enqueueTimeUs - du.receiveTimeUs) / 1000 : nil,
                          queueMs: now >= du.enqueueTimeUs ? Double(now - du.enqueueTimeUs) / 1000 : nil,
                          at: CACurrentMediaTime())
    }
    func decoded(startedUs: UInt64) {
        let now = LiGetMicroseconds()
        if now >= startedUs { telemetry.decoded(milliseconds: Double(now - startedUs) / 1000) }
    }
    func dropped() { telemetry.dropped() }
    func paced(dropped n: Int) { telemetry.paced(dropped: n) }
}

/// The last lines from a stream, for its error message and Diagnostics.
final class StreamLog: @unchecked Sendable {
    static let shared = StreamLog()
    private let lock = NSLock()
    private var lines: [String] = []
    /// ~/Library/Logs/Nokcandu/Streams.log, for Diagnostics and troubleshooting.
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nokcandu/Streams.log")
    private let fileQueue = DispatchQueue(label: "nokcandu.streamlog")
    /// The same line again and again (the stream core asks for a key frame on every frame it can't use) is
    /// written once and then counted, so it can't push everything else out of the log.
    private var lastLine = "", repeats = 0
    func add(_ s: String) {
        lock.lock()
        if s == lastLine { repeats += 1; if repeats < 3 || repeats % 1000 == 0 { lock.unlock(); writeRepeat(s, count: repeats) } else { lock.unlock() }; return }
        let skipped = repeats; lastLine = s; repeats = 0
        lines.append(s); if lines.count > 400 { lines.removeFirst(lines.count - 400) }; lock.unlock()
        if skipped >= 3 { write("(the line before repeated \(skipped) times in all)") }
        write(s)
        #if DEBUG
        print("[stream]", s)
        #endif
    }
    private func writeRepeat(_ s: String, count: Int) { write(count < 3 ? s : "\(s) (×\(count))") }
    private func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        fileQueue.async {
            let url = StreamLog.file
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                if (try? h.seekToEnd()) ?? 0 > 2_000_000 {
                    // Full: the log so far becomes Streams.previous.log (replacing the one before), not lost.
                    try? h.close()
                    let previous = url.deletingLastPathComponent().appendingPathComponent("Streams.previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try? FileManager.default.moveItem(at: url, to: previous)
                    try? Data(line.utf8).write(to: url)
                    return
                }
                h.write(Data(line.utf8)); try? h.close()
            } else { try? Data(line.utf8).write(to: url) }
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock(); add("— new stream —") }
}
