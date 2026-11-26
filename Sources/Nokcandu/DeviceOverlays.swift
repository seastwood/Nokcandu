import AppKit
import Metal
import NokcanduCore

/// The headphone-motion picture: a small panel of its own beside the controller overlay, showing where the head
/// points, the dead zone, how far it reaches, and which directions it's pressing. Shown when the controller
/// overlay is on, the active profile uses headphone motion, and it's switched on in the overlay's settings.
/// Placed by its own position and size. In a full-screen stream it's drawn into the frames with the controller
/// (one more small picture copied over the frame; it's redrawn only when it changes, never in the frame).
@MainActor
final class HeadMotionOverlay {
    static let shared = HeadMotionOverlay()

    struct State: Equatable {
        var x: Double, y: Double
        /// Dead zone as a fraction of the full reach.
        var dead: Double
        var active: Bool
        var output: PadHeadMotionSettings.Output
        var sectors: Int = 4
    }

    private var state: State?
    private var shown: (State, [String]?, [Bool], String)?
    private var panel: NSPanel?
    private var imageView: NSImageView?
    let streamImage = StreamImageDrawer()
    private var inStream = false
    private var settings = ControllerOverlaySettings.DevicePanel()
    private var on = false
    private var highlight = NSColor.systemBlue
    private var screen: NSScreen?
    /// Shown and draggable while the controller overlay is being moved, even without head motion.
    private var arranging = false
    var dragging = false

    /// Whether anyone's looking: the head-motion tracker skips the work otherwise.
    var wanted: Bool { on }

    /// From the controller overlay whenever its settings apply.
    func configure(_ s: ControllerOverlaySettings, overlayOn: Bool, screen: NSScreen?, highlight: NSColor) {
        settings = s.headMotion; on = overlayOn && s.headMotion.shown; self.screen = screen; self.highlight = highlight
        shown = nil
        refresh()
    }

    /// From the head-motion tracker: where the head points now (nil: stopped).
    func moved(_ s: State?) {
        guard on else { return }
        if let s, let old = state, old.active == s.active, old.output == s.output, abs(old.x - s.x) < 0.01, abs(old.y - s.y) < 0.01 { return }
        state = s
        refresh()
    }

    /// The controller overlay is being moved: show this one too, and let it be dragged.
    func arrange(_ on: Bool) {
        arranging = on; shown = nil
        panel?.ignoresMouseEvents = !on
        refresh()
    }

    /// Dragged to a new place: saved with the overlay's settings.
    fileprivate func dragged() {
        guard let p = panel, let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: p.frame.midX, y: p.frame.midY)) }) ?? p.screen else { return }
        var next = ControllerOverlay.shared.settings
        next.headMotion.positionX = (p.frame.midX - s.frame.minX) / s.frame.width
        next.headMotion.positionY = (p.frame.midY - s.frame.minY) / s.frame.height
        ControllerOverlay.shared.settings = next
    }

    /// The controller overlay went into a stream's frames (true) or back over the screen (false).
    func streaming(_ yes: Bool) { inStream = yes; refresh() }

    var size: CGSize { CGSize(width: settings.size.rounded(), height: settings.size.rounded()) }

    /// Where it goes in a stream: points from the screen's top left.
    func streamRect(screenFrame f: CGRect) -> CGRect {
        let s = size
        var o = CGPoint(x: f.width * settings.positionX - s.width / 2, y: f.height * settings.positionY - s.height / 2)
        o.x = min(max(o.x, 0), f.width - s.width); o.y = min(max(o.y, 0), f.height - s.height)
        return CGRect(x: o.x, y: f.height - o.y - s.height, width: s.width, height: s.height)
    }

    private func refresh() {
        let headOn = on && PadHeadTracking.shared.enabled && state != nil
        guard headOn || (arranging && settings.shown), let state = state ?? (arranging ? State(x: 0, y: 0, dead: 0.3, active: false, output: .mouse) : nil) else {
            panel?.orderOut(nil); streamImage.set(nil, device: nil); return
        }
        // Which directions it presses, from the stick its motion stands in for.
        var around: [String]?, lit = [false, false, false, false]
        var radial: [(text: String, lit: Bool)]?
        if state.output == .directions {
            // Its own directions: each one's mapping round the circle, the one held lit.
            let pad = DesktopPad.shared, held = pad.overlayLive().held
            var items: [(String, Bool)] = []
            for i in PadHeadDirections.inputs(state.sectors) {
                var t = ""
                if let p = pad.overlayProfile, !p.layers.isEmpty {
                    let layer = min(max(0, pad.overlayLayer), p.layers.count - 1)
                    if let b = p.layers[layer].bindings[i] ?? p.layers[0].bindings[i], !b.isEmpty { t = PadLabel.text(b, macros: p.macros, menus: p.menus)?.main ?? "" }
                }
                items.append((t, held.contains(i)))
            }
            radial = items
            lit = items.map(\.1)
        } else if state.output != .mouse {
            let side = state.output == .leftStick ? 0 : 1, pad = DesktopPad.shared
            if let p = pad.overlayProfile, !p.layers.isEmpty {
                let layer = min(max(0, pad.overlayLayer), p.layers.count - 1)
                let sticks = p.sticks.indices.contains(layer) ? p.sticks[layer] : (p.sticks.first ?? [])
                if sticks.indices.contains(side) {
                    func text(_ i: PadProfiles.Input) -> PadLabel.Text? {
                        guard let b = p.layers[layer].bindings[i] ?? p.layers[0].bindings[i], !b.isEmpty else { return nil }
                        return PadLabel.text(b, macros: p.macros, menus: p.menus)
                    }
                    around = OverlayMappingRules.stick(sticks[side], side: side, label: text)?.around
                }
            }
            let held = pad.overlayLive().held
            lit = PadProfiles.Input.stickDirections(side).map(held.contains)
            if lit == [false, false, false, false], state.active {
                // Not a directions stick: light what the stick is pushed toward.
                lit = [state.y > 0.5, state.y < -0.5, state.x < -0.5, state.x > 0.5]
            }
        }
        let title = state.output == .mouse ? "Head → mouse" : state.output == .leftStick ? "Head → left stick" : state.output == .rightStick ? "Head → right stick" : "Head menu"
        if let radial { around = radial.map(\.text) }
        if let s = shown, s.0 == state, s.1 == around, s.2 == lit, s.3 == title { return }
        shown = (state, around, lit, title)
        guard let image = HeadMotionImage.draw(state, around: around, lit: lit, title: title, highlight: highlight, size: size, radial: radial != nil) else { return }
        if inStream && !arranging {
            panel?.orderOut(nil)
            streamImage.set(image, device: streamImage.device)
        } else {
            streamImage.set(nil, device: nil)
            showPanel(image)
        }
    }

    private func showPanel(_ image: CGImage) {
        let p = panel ?? padOverlayPanel()
        if panel == nil {
            let v = HeadPanelView(frame: .zero); v.imageScaling = .scaleProportionallyUpOrDown
            v.onDragEnd = { [weak self] in self?.dragged() }
            p.contentView = v; panel = p; imageView = v
        }
        p.ignoresMouseEvents = !arranging
        imageView?.image = NSImage(cgImage: image, size: size)
        if let s = screen ?? NSScreen.main {
            let f = s.frame, sz = size
            var o = CGPoint(x: f.minX + f.width * settings.positionX - sz.width / 2, y: f.minY + f.height * settings.positionY - sz.height / 2)
            o.x = min(max(o.x, f.minX), f.maxX - sz.width); o.y = min(max(o.y, f.minY), f.maxY - sz.height)
            let r = NSRect(origin: o, size: sz)
            if p.frame.size != r.size || (!dragging && p.frame != r) { p.setFrame(r, display: true) }
        }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func tearDown() { on = false; state = nil; shown = nil; panel?.orderOut(nil); panel = nil; imageView = nil; streamImage.set(nil, device: nil) }
}

/// The head-motion picture.
/// The head-motion picture's view: draggable while the overlay is being moved.
final class HeadPanelView: NSImageView {
    var onDragEnd: (() -> Void)?
    private var start: (mouse: CGPoint, origin: CGPoint)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { if let w = window { start = (NSEvent.mouseLocation, w.frame.origin); HeadMotionOverlay.shared.dragging = true } }
    override func mouseDragged(with e: NSEvent) {
        guard let start, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(CGPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y))
    }
    override func mouseUp(with e: NSEvent) {
        if start != nil { onDragEnd?() }
        start = nil; HeadMotionOverlay.shared.dragging = false
    }
}

@MainActor
enum HeadMotionImage {
    static func draw(_ s: HeadMotionOverlay.State, around: [String]?, lit: [Bool], title: String, highlight: NSColor, size: CGSize, radial: Bool = false) -> CGImage? {
        let scale: CGFloat = 2, w = size.width * scale, h = size.height * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let white = NSColor.white
        // A clean circle: its reach, dead zone and (unless it is a radial menu) a cross.
        let c = CGPoint(x: w / 2, y: h / 2), R = w * 0.33
        // Semi-transparent inside the dial only, so it reads over any game without a ring around it.
        ctx.setFillColor(NSColor(white: 0.06, alpha: 0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))

        ctx.setStrokeColor(white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(2 * scale)
        ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        if !radial {
            ctx.setLineWidth(1 * scale)
            ctx.move(to: CGPoint(x: c.x - R, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + R, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - R)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + R)); ctx.strokePath()
        }
        let d = max(R * 0.04, R * s.dead)
        ctx.setFillColor(white.withAlphaComponent(0.16).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d))
        if radial, let names = around, !names.isEmpty {
            // A radial menu: a wedge per direction (clockwise from up), its mapping in it, the held one lit; the
            // inner circle is how far to turn to pick one.
            let n = names.count, width = 2 * Double.pi / Double(n), inner = R * CGFloat(s.dead)
            for i in 0..<n {
                let mid = Double.pi / 2 - Double(i) * width          // clockwise from up, in CG's counter-clockwise angles
                let a0 = mid - width / 2, a1 = mid + width / 2
                let path = CGMutablePath()
                path.addArc(center: c, radius: R, startAngle: a0, endAngle: a1, clockwise: false)
                path.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
                path.closeSubpath()
                let on = lit.indices.contains(i) && lit[i]
                ctx.addPath(path); ctx.setFillColor((on ? highlight.withAlphaComponent(0.6) : white.withAlphaComponent(0.07)).cgColor); ctx.fillPath()
                ctx.addPath(path); ctx.setStrokeColor(white.withAlphaComponent(0.3).cgColor); ctx.setLineWidth(1.5 * scale); ctx.strokePath()
                let r = (R + inner) / 2, p = CGPoint(x: c.x + cos(mid) * r, y: c.y + sin(mid) * r)
                let box = CGRect(x: p.x - w * 0.11, y: p.y - w * 0.06, width: w * 0.22, height: w * 0.12)
                label(names[i].isEmpty ? "·" : names[i], in: box, size: w * (n == 8 ? 0.065 : 0.085), color: on ? white : white.withAlphaComponent(names[i].isEmpty ? 0.35 : 0.85))
            }
            let p = CGPoint(x: c.x + CGFloat(max(-1, min(1, s.x))) * R, y: c.y + CGFloat(max(-1, min(1, s.y))) * R), dot = w * 0.045
            ctx.setFillColor((s.active ? white : white.withAlphaComponent(0.5)).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot))
            return ctx.makeImage()
        }
        // Directions it presses, around the edge.
        let spots = [CGPoint(x: c.x, y: c.y + R + w * 0.07), CGPoint(x: c.x, y: c.y - R - w * 0.07),
                     CGPoint(x: c.x - R - w * 0.08, y: c.y), CGPoint(x: c.x + R + w * 0.08, y: c.y)]
        let names = around ?? (s.output == .mouse ? ["", "", "", ""] : ["↑", "↓", "←", "→"])
        for i in 0..<4 where !names[i].isEmpty {
            let on = lit.indices.contains(i) && lit[i]
            let r = CGRect(x: spots[i].x - w * 0.08, y: spots[i].y - w * 0.06, width: w * 0.16, height: w * 0.12)
            if on { ctx.setFillColor(highlight.withAlphaComponent(0.55).cgColor); ctx.fillEllipse(in: r.insetBy(dx: -w * 0.01, dy: -w * 0.01)) }
            label(names[i], in: r, size: w * 0.085, color: on ? white : white.withAlphaComponent(0.7))
        }
        // Where the head points.
        let p = CGPoint(x: c.x + CGFloat(max(-1, min(1, s.x))) * R, y: c.y + CGFloat(max(-1, min(1, s.y))) * R)
        let dot = w * 0.055
        ctx.setFillColor((s.active ? highlight : white.withAlphaComponent(0.6)).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot))
        return ctx.makeImage()
    }

    private static func label(_ s: String, in box: CGRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        var font = NSFont.systemFont(ofSize: size, weight: .bold)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        var t = NSAttributedString(string: s, attributes: attrs)
        if t.size().width > box.width {
            font = NSFont.systemFont(ofSize: size * box.width / t.size().width, weight: .bold)
            attrs[.font] = font; t = NSAttributedString(string: s, attributes: attrs)
        }
        let ts = t.size()
        t.draw(in: CGRect(x: box.minX, y: box.midY - ts.height / 2, width: box.width, height: ts.height))
    }
}

/// A flat picture drawn over a stream's frames: set from the main thread when it changes (uploaded then), copied
/// onto each frame on the render queue. Nothing here waits.
final class StreamImageDrawer: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var texture: MTLTexture?, rect = CGRect.zero, screenWidth: CGFloat = 1, opacity: Float = 1   // guarded by `lock`
    private(set) var device: MTLDevice?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]   // render queue
    private var library: MTLLibrary?, sampler: MTLSamplerState?

    /// Main thread: the device frames are drawn with (from the stream's renderer).
    func use(_ d: MTLDevice?) {
        guard d !== device else { return }
        device = d
        library = d.flatMap { try? $0.makeLibrary(source: StreamOverlayDrawer.shader, options: nil) }
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sampler = d?.makeSamplerState(descriptor: sd)
        os_unfair_lock_lock(&lock); texture = nil; os_unfair_lock_unlock(&lock)
        pipelines = [:]
    }

    /// Main thread: a new picture (nil: nothing).
    func set(_ image: CGImage?, device d: MTLDevice?) {
        var t: MTLTexture?
        if let image, let d = d ?? device {
            // Into premultiplied BGRA (whatever the image's own layout), then up to the GPU.
            let w = image.width, h = image.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = .shaderRead
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let tex = d.makeTexture(descriptor: desc) {
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let bytes = ctx.data {
                    tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
                    t = tex
                }
            }
        }
        os_unfair_lock_lock(&lock); texture = t; os_unfair_lock_unlock(&lock)
    }

    func place(_ r: CGRect, screenWidth w: CGFloat, opacity o: Double) {
        os_unfair_lock_lock(&lock); rect = r; screenWidth = max(1, w); opacity = Float(o); os_unfair_lock_unlock(&lock)
    }

    /// Render queue.
    func draw(_ buffer: MTLCommandBuffer, _ target: MTLTexture) {
        os_unfair_lock_lock(&lock); let t = texture, r = rect, w = screenWidth, o = opacity; os_unfair_lock_unlock(&lock)
        guard let t, r.width > 0, let sampler, let pipeline = pipeline(target.pixelFormat),
              let enc = buffer.makeRenderCommandEncoder(descriptor: {
                  let p = MTLRenderPassDescriptor()
                  p.colorAttachments[0].texture = target; p.colorAttachments[0].loadAction = .load; p.colorAttachments[0].storeAction = .store
                  return p }()) else { return }
        let s = CGFloat(target.width) / w
        enc.setRenderPipelineState(pipeline)
        enc.setViewport(MTLViewport(originX: Double(r.minX * s), originY: Double(r.minY * s), width: Double(r.width * s), height: Double(r.height * s), znear: 0, zfar: 1))
        enc.setFragmentTexture(t, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        var opacity = o
        enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        guard let device, let library, let v = library.makeFunction(name: "overlay_vertex"), let f = library.makeFunction(name: "overlay_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f
        let c = d.colorAttachments[0]!
        c.pixelFormat = format; c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let p = try? device.makeRenderPipelineState(descriptor: d)
        pipelines[format] = p
        return p
    }
}
