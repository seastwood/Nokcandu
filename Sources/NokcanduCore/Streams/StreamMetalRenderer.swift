// SPDX-License-Identifier: GPL-3.0-only
// Draws decoded frames with Metal on a CAMetalLayer: YUV-to-RGB in a shader, HDR through EDR, and optionally
// without waiting for the display's refresh (V-sync off), which the system display layer can't do. Follows
// Moonlight PC's VTMetalRenderer (vt_metal.mm and vt_renderer.metal, GPL-3.0).
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

public final class StreamMetalRenderer: @unchecked Sendable {
    public struct Frame {
        public let image: CVPixelBuffer
        /// When the frame's first packet arrived and when its decoding finished (CACurrentMediaTime).
        public let receivedAt: CFTimeInterval?
        public let decodedAt: CFTimeInterval
        public init(image: CVPixelBuffer, receivedAt: CFTimeInterval?, decodedAt: CFTimeInterval) {
            self.image = image; self.receivedAt = receivedAt; self.decodedAt = decodedAt
        }
    }

    /// Where the renderer's messages go (the app's stream log).
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    public let layer = CAMetalLayer()
    public let deviceName: String
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let library: MTLLibrary
    private let renderQueue = DispatchQueue(label: "nokcandu.stream.metal", qos: .userInteractive)

    /// Guarded by `lock`: the newest frame not yet drawn (an older one waiting is replaced, so the screen never
    /// falls behind), whether the render queue is draining, and the host's HDR metadata.
    private var lock = os_unfair_lock()
    private var pending: Frame?
    private var draining = false
    /// Frames handed to the layer that haven't reached the screen yet, when the last was handed over, and how long
    /// frames take to reach the screen (smoothed). Shown directly (full screen), a frame is on screen within a few
    /// milliseconds. Composited by the window server (a window, a moment after switching Spaces), frames wait for the
    /// display's refresh: decoded faster than that, they queued three deep (~70 ms at 60 Hz). Then only one frame
    /// waits for the screen, and newer ones replace the next to draw.
    private var unpresented = 0, lastHandedOver: CFTimeInterval = 0, screenLag: CFTimeInterval = 0
    private var hdrMetadata: StreamHDRMetadata?
    private var hdrVersion = 0
    /// The colour space of the screen showing the stream (main thread sets it; nil until known).
    private var displaySpace: CGColorSpace?
    /// Pixels at the top of the layer kept clear of the picture (see StreamView.topInset).
    private var topInset: CGFloat = 0

    // Render queue only.
    private var configured: Config?
    private var display: CGColorSpace?
    private var params = [Float](repeating: 0, count: 36)
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var failures = 0, failed = false

    /// A frame was drawn and handed to the display (render queue), and the time it was actually shown (Metal's
    /// presented handler: CACurrentMediaTime of the display update).
    public var onDrawn: ((Frame) -> Void)?
    public var onScreen: ((Frame, CFTimeInterval) -> Void)?
    /// A waiting frame was replaced by a newer one before it could be drawn.
    public var onReplaced: (() -> Void)?
    /// Metal can't show this stream (any thread): fall back to the display layer.
    public var onFailure: ((String) -> Void)?

    /// Something drawn over each frame before it's shown (the controller overlay, the statistics), in the frame's own command
    /// buffer. Drawing it here instead of in a window above keeps the stream a single opaque layer, so macOS's
    /// direct-to-display path stays on: any window over a full-screen stream makes the window server composite
    /// every frame, which adds frames of delay with V-sync off. Each draws into the frame's own render pass (its
    /// encoder, still open): a pass of its own would load and store the whole frame again on Apple's tile-based GPUs,
    /// a full-screen read and write per overlay. An overlay sets its own pipeline and viewport.
    public typealias Overlay = (_ encoder: MTLRenderCommandEncoder, _ target: MTLTexture) -> Void
    private var overlays: [(key: String, draw: Overlay)] = []   // guarded by `lock`; drawn in key order
    /// Sets or (nil) removes one overlay: "controller" (the controller overlay), "stats" (the statistics).
    public func setOverlay(_ o: Overlay?, key: String = "controller") {
        os_unfair_lock_lock(&lock)
        overlays.removeAll { $0.key == key }
        if let o { overlays.append((key, o)); overlays.sort { $0.key < $1.key } }
        os_unfair_lock_unlock(&lock)
    }
    public var metalDevice: MTLDevice { device }

    private var gpuSum = 0.0, gpuCount = 0, gpuMax = 0.0   // guarded by `lock`
    /// The GPU's time per frame (drawing, colour conversion and overlays) since the last call: average and longest,
    /// in ms. Nil before a frame has been timed.
    public func takeGPUTime() -> (average: Double, max: Double)? {
        os_unfair_lock_lock(&lock); defer { gpuSum = 0; gpuCount = 0; gpuMax = 0; os_unfair_lock_unlock(&lock) }
        return gpuCount > 0 ? (gpuSum / Double(gpuCount), gpuMax) : nil
    }

    private struct Config: Equatable {
        var pixelFormat: OSType, matrix: String?, transfer: String?, primaries: String?, chroma: String?, hdrVersion: Int
    }

    /// Nil, with the reason, when this Mac's Metal can't be set up.
    public static func make(vsync: Bool) -> (StreamMetalRenderer?, String?) {
        guard let device = preferredDevice() else { return (nil, "no Metal device") }
        do { return (try StreamMetalRenderer(device: device, vsync: vsync), nil) } catch { return (nil, "\(error)") }
    }

    /// Moonlight's choice: a low-power (Intel integrated) or unified-memory (Apple silicon) GPU, then any built-in one.
    private static func preferredDevice() -> MTLDevice? {
        let all = MTLCopyAllDevices()
        return all.first(where: { $0.isLowPower || $0.hasUnifiedMemory }) ?? all.first(where: { !$0.isRemovable }) ?? MTLCreateSystemDefaultDevice()
    }

    private struct SetupError: Error, CustomStringConvertible { let description: String }

    private init(device: MTLDevice, vsync: Bool) throws {
        self.device = device
        deviceName = device.name
        guard let q = device.makeCommandQueue() else { throw SetupError(description: "no command queue") }
        commandQueue = q
        var cache: CVMetalTextureCache?
        // kCVMetalTextureUsage belongs in the texture attributes, not the cache's (Moonlight, November 2026).
        let textureAttributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
        guard CVMetalTextureCacheCreate(nil, nil, device, textureAttributes, &cache) == kCVReturnSuccess, let cache else {
            throw SetupError(description: "no texture cache")
        }
        textureCache = cache
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Three drawables are needed for macOS's direct-to-display path, which V-sync off (tearing) also requires;
        // with two, the window server composites every frame and latency is higher (Moonlight's finding).
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = vsync
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        _ = try pipeline(for: .bgra8Unorm)
        if vsync { startDisplayLink() }
    }

    /// Main thread: wait for the display's refresh (true) or show each frame at once (false).
    public var vsync: Bool {
        get { layer.displaySyncEnabled }
        set {
            layer.displaySyncEnabled = newValue
            if newValue { startDisplayLink() } else { stopDisplayLink() }
        }
    }

    // MARK: V-sync on: a CAMetalDisplayLink

    /// With V-sync on, frames presented as they're decoded queued in the layer for refreshes and reached the screen
    /// two or three refreshes late (~70 ms at 60 Hz, November 19), and letting only one through at a time halved the
    /// frame rate (~43 ms, 30 fps). Moonlight's answer: a CAMetalDisplayLink with a frame latency of one, which hands
    /// over a drawable just before each refresh; the newest decoded frame is drawn into it. It waits for a frame
    /// until just before the drawable is due (drawing takes about a millisecond): waiting only half that time sent a
    /// frame arriving in the second half on to the next refresh, a whole refresh later (about 40 ms in all at 60 Hz,
    /// November 20). It runs on its own thread so the main thread (input) is never held up.
    private var link: CAMetalDisplayLink?
    private var linkThread: Thread?
    private let frameReady = NSCondition()
    private lazy var linkDelegate = LinkDelegate(self)

    private final class LinkDelegate: NSObject, CAMetalDisplayLinkDelegate {
        weak var renderer: StreamMetalRenderer?
        init(_ r: StreamMetalRenderer) { renderer = r }
        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            renderer?.linkUpdate(update)
        }
    }

    private var usesLink: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return link != nil }

    private func startDisplayLink() {
        os_unfair_lock_lock(&lock); let running = link != nil; os_unfair_lock_unlock(&lock)
        guard !running else { return }
        let l = CAMetalDisplayLink(metalLayer: layer)
        l.preferredFrameLatency = 1
        if let hz = refreshRate { l.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz) }
        l.delegate = linkDelegate
        os_unfair_lock_lock(&lock); link = l; os_unfair_lock_unlock(&lock)
        let t = Thread { [weak l] in
            guard let l else { return }
            l.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) }
        }
        t.name = "nokcandu.stream.vsync"
        t.qualityOfService = .userInteractive
        linkThread = t
        t.start()
    }

    deinit { link?.invalidate(); linkThread?.cancel() }

    private func stopDisplayLink() {
        os_unfair_lock_lock(&lock); let l = link; link = nil; os_unfair_lock_unlock(&lock)
        l?.invalidate()
        linkThread?.cancel(); linkThread = nil
        // A frame waiting for the link goes out the normal way.
        os_unfair_lock_lock(&lock)
        let start = pending != nil && !draining
        if start { draining = true }
        os_unfair_lock_unlock(&lock)
        if start { renderQueue.async { [weak self] in self?.drain() } }
    }

    /// The link's thread, just before a refresh: draw the newest frame into its drawable.
    fileprivate func linkUpdate(_ update: CAMetalDisplayLink.Update) {
        let budget = update.targetTimestamp - CACurrentMediaTime() - Self.drawMargin
        var f: Frame?
        frameReady.lock()
        os_unfair_lock_lock(&lock); f = pending; pending = nil; os_unfair_lock_unlock(&lock)
        if f == nil, budget > 0 {
            _ = frameReady.wait(until: Date(timeIntervalSinceNow: budget))
            os_unfair_lock_lock(&lock); f = pending; pending = nil; os_unfair_lock_unlock(&lock)
        }
        frameReady.unlock()
        guard let f else { return }
        renderQueue.sync { autoreleasepool { draw(f, into: update.drawable) } }
    }

    /// How long before the drawable is due a frame must be in hand to be drawn in time.
    static let drawMargin = 0.0025

    /// The screen's top refresh rate: V-sync on asks for it (a ProMotion or other variable-rate screen otherwise
    /// may run slower).
    private var refreshRate: Float?
    public func setRefreshRate(_ hz: Float) {
        guard hz > 0 else { return }
        os_unfair_lock_lock(&lock); refreshRate = hz; let l = link; os_unfair_lock_unlock(&lock)
        l?.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
    }

    /// Main thread: the layer's size in points and the screen's scale.
    public func resize(_ bounds: CGRect, scale: CGFloat, topInset: CGFloat = 0) {
        os_unfair_lock_lock(&lock); self.topInset = max(0, topInset * scale); os_unfair_lock_unlock(&lock)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
    }

    /// Main thread: the colour space of the screen the stream is on (`NSScreen.colorSpace?.cgColorSpace`). SDR is
    /// drawn already converted to it and the layer is tagged with it, so the window server has no colour
    /// conversion to do: it can then send the layer straight to the display, which V-sync off (tearing) and the
    /// lowest latency need. With any conversion left, every frame is composited and waits for a refresh.
    public func setDisplayColorSpace(_ space: CGColorSpace?) {
        os_unfair_lock_lock(&lock)
        let changed = space?.name != displaySpace?.name || (space == nil) != (displaySpace == nil)
        if changed { displaySpace = space; hdrVersion += 1 }
        os_unfair_lock_unlock(&lock)
    }

    /// The host's HDR metadata (nil: none or HDR off), used for the next frames.
    public func setHDR(_ md: StreamHDRMetadata?) {
        os_unfair_lock_lock(&lock); hdrMetadata = md; hdrVersion += 1; os_unfair_lock_unlock(&lock)
    }

    /// Any thread: draws this frame as soon as the render queue is free.
    public func submit(_ f: Frame) {
        os_unfair_lock_lock(&lock)
        let replaced = pending != nil
        pending = f
        let linked = link != nil
        let start = !linked && !draining
        if start { draining = true }
        os_unfair_lock_unlock(&lock)
        if replaced { onReplaced?() }
        if linked { frameReady.lock(); frameReady.signal(); frameReady.unlock() }
        if start { renderQueue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            os_unfair_lock_lock(&lock)
            guard let f = pending, link == nil else { draining = false; os_unfair_lock_unlock(&lock); return }
            // Composited: wait for the frame on its way to the screen (its arrival starts drawing again), unless
            // it's overdue (a frame macOS never shows mustn't stop the stream).
            if unpresented > 0 && screenLag > 0.010 && CACurrentMediaTime() - lastHandedOver < 0.1 {
                draining = false; os_unfair_lock_unlock(&lock); return
            }
            pending = nil
            os_unfair_lock_unlock(&lock)
            autoreleasepool { draw(f) }
        }
    }

    // MARK: Drawing (render queue)

    private func draw(_ f: Frame, into given: CAMetalDrawable? = nil) {
        guard !failed else { return }
        let image = f.image
        guard let pipeline = prepare(image) else { return }
        guard let (luma, chroma, textures) = planeTextures(image) else {
            failures += 1
            // Moonlight found some discrete/external GPUs can't import decoded frames: give up after a run of failures.
            if failures >= 30 { fail("Metal couldn't read the decoded frames") }
            return
        }
        failures = 0
        guard let drawable = given ?? layer.nextDrawable(), let buffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = encode(image, luma: luma, chroma: chroma, pipeline: pipeline, into: drawable.texture, buffer: buffer) else { return }
        os_unfair_lock_lock(&lock); let over = overlays; os_unfair_lock_unlock(&lock)
        for o in over { o.draw(encoder, drawable.texture) }
        encoder.endEncoding()
        let frame = f, counted = given == nil, handedOver = CACurrentMediaTime()
        if counted { os_unfair_lock_lock(&lock); unpresented += 1; lastHandedOver = handedOver; os_unfair_lock_unlock(&lock) }
        drawable.addPresentedHandler { [weak self] d in
            guard let self else { return }
            if d.presentedTime > 0 { self.onScreen?(frame, d.presentedTime) }
            guard counted else { return }
            os_unfair_lock_lock(&self.lock)
            self.unpresented = max(0, self.unpresented - 1)
            if d.presentedTime > 0 { self.screenLag += (max(0, d.presentedTime - handedOver) - self.screenLag) * 0.2 }
            let kick = self.pending != nil && !self.draining && self.link == nil
            if kick { self.draining = true }
            os_unfair_lock_unlock(&self.lock)
            if kick { self.renderQueue.async { [weak self] in self?.drain() } }
        }
        // The CVMetalTextures must live until the GPU has read them; the GPU's time for the frame is noted then.
        buffer.addCompletedHandler { [weak self] b in
            withExtendedLifetime(textures) {}
            let ms = (b.gpuEndTime - b.gpuStartTime) * 1000
            guard let self, ms > 0, ms < 1000 else { return }
            os_unfair_lock_lock(&self.lock); self.gpuSum += ms; self.gpuCount += 1; self.gpuMax = max(self.gpuMax, ms); os_unfair_lock_unlock(&self.lock)
        }
        buffer.present(drawable)
        buffer.commit()
        onDrawn?(f)
    }

    /// Picks up a change of format or colour for this frame; the pipeline for the layer's pixel format.
    private func prepare(_ image: CVPixelBuffer) -> MTLRenderPipelineState? {
        let format = CVPixelBufferGetPixelFormatType(image)
        guard Self.planeFormats(format) != nil else { fail("frames in an unsupported pixel format (\(format))"); return nil }
        os_unfair_lock_lock(&lock); let version = hdrVersion, md = hdrMetadata, display = displaySpace; os_unfair_lock_unlock(&lock)
        self.display = display
        let config = Config(pixelFormat: format, matrix: Self.attachment(image, kCVImageBufferYCbCrMatrixKey),
                            transfer: Self.attachment(image, kCVImageBufferTransferFunctionKey),
                            primaries: Self.attachment(image, kCVImageBufferColorPrimariesKey),
                            chroma: Self.attachment(image, kCVImageBufferChromaLocationTopFieldKey), hdrVersion: version)
        if config != configured { configure(config, md: md) }
        guard let p = try? pipeline(for: layer.pixelFormat) else { fail("no Metal pipeline"); return nil }
        return p
    }

    /// The luma and chroma planes as Metal textures (no copy: they share the decoder's IOSurface).
    private func planeTextures(_ image: CVPixelBuffer) -> (MTLTexture, MTLTexture, [CVMetalTexture])? {
        guard let planes = Self.planeFormats(CVPixelBufferGetPixelFormatType(image)) else { return nil }
        var textures: [CVMetalTexture] = []
        for (plane, pixelFormat) in planes.enumerated() {
            var t: CVMetalTexture?
            let rc = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, image, nil, pixelFormat,
                                                               CVPixelBufferGetWidthOfPlane(image, plane), CVPixelBufferGetHeightOfPlane(image, plane),
                                                               plane, &t)
            guard rc == kCVReturnSuccess, let t else { return nil }
            textures.append(t)
        }
        guard textures.count == 2, let luma = CVMetalTextureGetTexture(textures[0]), let chroma = CVMetalTextureGetTexture(textures[1]) else { return nil }
        return (luma, chroma, textures)
    }

    /// Draws the picture into `target`: its visible area (the clean aperture: a stream coded at 1088 lines shows
    /// 1080) fitted inside, keeping its shape, on black.
    /// Draws the frame and returns its render pass's encoder, still open for the overlays (the caller ends it).
    private func encode(_ image: CVPixelBuffer, luma: MTLTexture, chroma: MTLTexture, pipeline: MTLRenderPipelineState,
                        into target: MTLTexture, buffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        var clean = CVImageBufferGetCleanRect(image)
        if clean.width <= 0 || clean.height <= 0 { clean = CGRect(origin: .zero, size: size) }
        os_unfair_lock_lock(&lock); let inset = min(Double(topInset), Double(target.height) / 2); os_unfair_lock_unlock(&lock)
        // Fitted inside the area below `inset`, then mapped back to the whole target's coordinates.
        let area = Double(target.height) - inset, share = Float(area / Double(target.height))
        var r = StreamColorConversion.fit(width: clean.width, height: clean.height, in: Double(target.width), area)
        r.y = -1 + (r.y + 1) * share; r.h *= share
        let u0 = Float(clean.minX / size.width), u1 = Float(clean.maxX / size.width)
        let v0 = Float(clean.minY / size.height), v1 = Float(clean.maxY / size.height)
        // x, y, z, w, u, v and padding: the shader's Vertex (float4 + float2, 32 bytes).
        var vertices: [Float] = [
            r.x, r.y, 0, 1, u0, v1, 0, 0,
            r.x, r.y + r.h, 0, 1, u0, v0, 0, 0,
            r.x + r.w, r.y, 0, 1, u1, v1, 0, 0,
            r.x + r.w, r.y + r.h, 0, 1, u1, v0, 0, 0,
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&params, length: params.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return encoder
    }

    /// For tests: draws one frame exactly as a stream would, into an offscreen 8-bit BGRA picture of this size,
    /// and returns its pixels (B, G, R, A, rows top to bottom). Nil if it can't be drawn.
    public func renderForTesting(_ image: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        renderQueue.sync {
            guard let pipelineForLayer = prepare(image), let planes = planeTextures(image) else { return nil }
            _ = pipelineForLayer
            guard let pipeline = try? pipeline(for: .bgra8Unorm) else { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .managed
            guard let target = device.makeTexture(descriptor: d), let buffer = commandQueue.makeCommandBuffer(),
                  let drawn = encode(image, luma: planes.0, chroma: planes.1, pipeline: pipeline, into: target, buffer: buffer) else { return nil }
            drawn.endEncoding()
            guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
            blit.synchronize(resource: target)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            lastGPUMillisecondsForTesting = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            withExtendedLifetime(planes.2) {}
            var out = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return out
        }
    }

    /// For tests: how long the GPU took for the last `renderForTesting` (the draw and the copy back for reading).
    public private(set) var lastGPUMillisecondsForTesting = 0.0

    /// For tests: the layer's colour setup after the last frame (pixel format, EDR on, EDR metadata set).
    public var layerStateForTesting: (pixelFormat: MTLPixelFormat, edr: Bool, edrMetadata: Bool) {
        renderQueue.sync { (layer.pixelFormat, layer.wantsExtendedDynamicRangeContent, layer.edrMetadata != nil) }
    }

    /// Colour conversion and the layer's colour space for frames like this one.
    private func configure(_ c: Config, md: StreamHDRMetadata?) {
        configured = c
        let tenBit = Self.isTenBit(c.pixelFormat)
        let conv = StreamColorConversion.params(StreamColorConversion.matrix(c.matrix, tenBit: tenBit), fullRange: Self.isFullRange(c.pixelFormat),
                                                bits: tenBit ? 10 : 8)
        let off = StreamColorConversion.chromaOffset(c.chroma, subsampled: !Self.is444(c.pixelFormat))
        params = conv.rows.flatMap { $0 + [0] } + conv.offsets + [0] + [off.x, off.y, 0, 0]
            + [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0] + [0, 0, 0, 0]       // no gamut conversion (set for SDR below)
        let pq = c.transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let hlg = c.transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if pq || hlg {
            // The shader outputs the PQ/HLG-encoded signal; macOS maps it to the display, tonemapping with the
            // host's metadata where the display has less range.
            layer.pixelFormat = .bgr10a2Unorm
            layer.colorspace = CGColorSpace(name: pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG)
            layer.wantsExtendedDynamicRangeContent = true
            if hlg { layer.edrMetadata = CAEDRMetadata.hlg }
            else if let md, let display = md.masteringDisplayColorVolume {
                layer.edrMetadata = CAEDRMetadata.hdr10(displayInfo: display, contentInfo: md.contentLightLevelInfo, opticalOutputScale: 203)
            } else { layer.edrMetadata = nil }
        } else {
            layer.pixelFormat = .bgra8Unorm
            layer.wantsExtendedDynamicRangeContent = false
            layer.edrMetadata = nil
            // SDR from a PC is sRGB: Sunshine encodes the desktop's sRGB values with the BT.709 matrix, so the shader's
            // RGB is already sRGB-encoded. Tagging the layer with the BT.709 colour space made macOS convert from the
            // camera transfer curve, brightening the mid-tones (washed out; seen November 19). Moonlight's Mac renderer
            // also ends up in sRGB. BT.2020 primaries keep their gamut with the sRGB curve.
            let bt2020 = c.primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
            if !bt2020, let display {
                // Present in the display's own colour space: on a wide-gamut (Display P3) screen the shader maps
                // sRGB primaries to P3; on an sRGB screen there's nothing to map.
                if display.isWideGamutRGB { params.replaceSubrange(20..<36, with: Self.srgbToP3 + [1, 0, 0, 0]) }
                layer.colorspace = display
                Self.log?("Video: Metal presents in the display's colour space (\(display.name.map { $0 as String } ?? "unnamed")\(display.isWideGamutRGB ? ", sRGB mapped to P3 in the shader" : ""))")
            } else {
                layer.colorspace = CGColorSpace(name: bt2020 ? CGColorSpace.itur_2020_sRGBGamma : CGColorSpace.sRGB)
            }
        }
        CATransaction.commit()
        Self.log?("Video: Metal draws \(Self.formatName(c.pixelFormat)) (\(c.matrix ?? "matrix unknown"), \(c.transfer ?? "transfer unknown")) on \(deviceName), V-sync \(layer.displaySyncEnabled ? "on" : "off")")
    }

    /// Linear BT.709/sRGB primaries to Display P3 (both D65), rows for R, G, B, padded to float4.
    private static let srgbToP3: [Float] = [
        0.8225, 0.1774, 0.0000, 0,
        0.0332, 0.9669, 0.0000, 0,
        0.0171, 0.0724, 0.9108, 0,
    ]

    private func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let p = pipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vs_draw")
        d.fragmentFunction = library.makeFunction(name: "ps_draw_biplanar")
        d.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: d)
        pipelines[format] = p
        return p
    }

    private func fail(_ why: String) {
        guard !failed else { return }
        failed = true
        Self.log?("Video: \(why); switching to the display layer")
        onFailure?(why)
    }

    // MARK: Pixel formats

    /// Metal formats for the luma and chroma planes of the decoder's bi-planar buffers. 10-bit values sit in the
    /// top bits of 16, so 16-bit normalised textures read them at the right scale.
    private static func planeFormats(_ f: OSType) -> [MTLPixelFormat]? {
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return [.r8Unorm, .rg8Unorm]
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return [.r16Unorm, .rg16Unorm]
        default: return nil
        }
    }
    private static func isTenBit(_ f: OSType) -> Bool { planeFormats(f)?.first == .r16Unorm }
    private static func isFullRange(_ f: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(f)
    }
    private static func is444(_ f: OSType) -> Bool {
        [kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(f)
    }
    private static func formatName(_ f: OSType) -> String {
        "\(isTenBit(f) ? "10" : "8")-bit \(is444(f) ? "4:4:4" : "4:2:0") \(isFullRange(f) ? "full" : "limited") range"
    }
    private static func attachment(_ image: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(image, key, nil) as? String
    }

    // MARK: Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float4 position [[ position ]];
        float2 texCoords;
    };

    // R, G and B rows applied to (Y, Cb, Cr) once the offsets are subtracted; chroma.xy is the chroma siting in luma pixels.
    struct Params {
        float4 row0;
        float4 row1;
        float4 row2;
        float4 offsets;
        float4 chroma;
        // Optional gamut mapping in linear light (flags.x = 1): sRGB → the display's primaries.
        float4 gamut0;
        float4 gamut1;
        float4 gamut2;
        float4 flags;
    };

    static float3 srgb_to_linear(float3 c) {
        c = saturate(c);
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }
    static float3 linear_to_srgb(float3 l) {
        l = saturate(l);
        return select(1.055 * pow(l, 1.0 / 2.4) - 0.055, l * 12.92, l <= 0.0031308);
    }

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    vertex Vertex vs_draw(constant Vertex *vertices [[ buffer(0) ]], uint id [[ vertex_id ]]) {
        return vertices[id];
    }

    fragment float4 ps_draw_biplanar(Vertex v [[ stage_in ]],
                                     constant Params &p [[ buffer(0) ]],
                                     texture2d<float> luma [[ texture(0) ]],
                                     texture2d<float> chroma [[ texture(1) ]]) {
        float2 offset = p.chroma.xy / float2(luma.get_width(), luma.get_height());
        float3 yuv = float3(luma.sample(s, v.texCoords).r, chroma.sample(s, v.texCoords + offset).rg) - p.offsets.xyz;
        float3 rgb = float3(dot(p.row0.xyz, yuv), dot(p.row1.xyz, yuv), dot(p.row2.xyz, yuv));
        if (p.flags.x > 0.5) {
            float3 l = srgb_to_linear(rgb);
            rgb = linear_to_srgb(float3(dot(p.gamut0.xyz, l), dot(p.gamut1.xyz, l), dot(p.gamut2.xyz, l)));
        }
        return float4(rgb, 1.0);
    }
    """
}
