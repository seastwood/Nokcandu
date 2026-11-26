import AppKit
import CoreGraphics
import NokcanduCore

/// What the overlay's controller shows on its parts while mappings are on.
struct OverlayMappings: Equatable {
    struct Cap: Equatable { var text: PadLabel.Text?; var own: String; var toggled: Bool }
    var buttons: [PadProfiles.Input: Cap] = [:]
    var pads: [Int: OverlayPadFace] = [:]
    var sticks: [Int: Cap] = [:]
}

/// Label pictures for the overlay's buttons and trackpads, drawn with Core Graphics into small textures. Cached by
/// what they show, so a label is drawn once and reused until it changes.
@MainActor
enum OverlayLabelImages {
    private static var cache: [String: CGImage] = [:]
    static let text = NSColor.white

    /// A button cap's label, `aspect` = width ÷ height of the cap. The mapped action is bright; a button that does
    /// what it's called shows its own name, dimmed. A hold or double tap goes small underneath; a toggle that's on
    /// gets a ring in the highlight colour.
    static func cap(_ c: OverlayMappings.Cap, aspect: CGFloat, highlight: NSColor) -> CGImage? {
        let key = "cap|\(c.text?.main ?? "")|\(c.text?.around?.joined(separator: ",") ?? "")|\(c.text?.second ?? "")|\(c.text?.toggles == true)|\(c.own)|\(c.toggled)|\(aspect)|\(highlight.hex)"
        if let i = cache[key] { return i }
        let h: CGFloat = 160, w = (h * max(0.5, min(3, aspect))).rounded()
        let img = draw(width: w, height: h) { ctx in
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            if c.toggled {
                ctx.setStrokeColor(highlight.cgColor); ctx.setLineWidth(10)
                ctx.strokeEllipse(in: r.insetBy(dx: 8, dy: 8))
            }
            if let t = c.text, let a = t.around, a.count == 4 {
                // Up, down, left, right at the cap's edges, like a compass.
                let b = CGSize(width: w * 0.34, height: h * 0.3)
                let spots = [CGPoint(x: w / 2, y: h * 0.8), CGPoint(x: w / 2, y: h * 0.2), CGPoint(x: w * 0.2, y: h / 2), CGPoint(x: w * 0.8, y: h / 2)]
                for (s, p) in zip(a, spots) {
                    fit(s, in: CGRect(x: p.x - b.width / 2, y: p.y - b.height / 2, width: b.width, height: b.height), weight: .bold, color: s == "·" ? text.withAlphaComponent(0.35) : text)
                }
                if !t.main.isEmpty { fit(t.main, in: CGRect(x: w * 0.38, y: h * 0.4, width: w * 0.24, height: h * 0.2), weight: .semibold, color: text.withAlphaComponent(0.7)) }
            } else if let t = c.text {
                if let second = t.second {
                    fit(t.main, in: CGRect(x: w * 0.1, y: h * 0.36, width: w * 0.8, height: h * 0.46), weight: .bold, color: text)
                    fit(second, in: CGRect(x: w * 0.15, y: h * 0.12, width: w * 0.7, height: h * 0.24), weight: .semibold, color: text.withAlphaComponent(0.8))
                } else {
                    fit(t.main, in: r.insetBy(dx: w * 0.12, dy: h * 0.18), weight: .bold, color: text)
                }
            } else {
                fit(c.own, in: r.insetBy(dx: w * 0.2, dy: h * 0.24), weight: .semibold, color: text.withAlphaComponent(0.38))
            }
        }
        cache[key] = img; trim()
        return img
    }

    /// A trackpad's face: its regions outlined, held ones lit, toggled ones ringed, each with its label; what the
    /// pad does as a whole in the middle; its click at the bottom.
    static func pad(_ f: OverlayPadFace, highlight: NSColor) -> CGImage? {
        let key = "pad|\(f.regions.map { "\($0.shape)\($0.text?.main ?? "")\($0.text?.second ?? "")\($0.active)\($0.toggled)\($0.at)" }.joined(separator: ";"))|\(f.centre ?? "")|\(f.click?.main ?? "")|\(f.clickActive)|\(highlight.hex)"
        if let i = cache[key] { return i }
        let s: CGFloat = 512, c = CGPoint(x: s / 2, y: s / 2), R = s / 2 - 6
        let img = draw(width: s, height: s) { ctx in
            for r in f.regions {
                let path = CGMutablePath()
                switch r.shape {
                case let .sector(from, to, inner, outer):
                    if to - from >= 359.9 {
                        path.addEllipse(in: CGRect(x: c.x - R * outer, y: c.y - R * outer, width: 2 * R * outer, height: 2 * R * outer))
                        path.addEllipse(in: CGRect(x: c.x - R * inner, y: c.y - R * inner, width: 2 * R * inner, height: 2 * R * inner))
                    } else {
                        let a0 = from * .pi / 180, a1 = to * .pi / 180
                        path.addArc(center: c, radius: R * outer, startAngle: a0, endAngle: a1, clockwise: false)
                        if inner > 0 { path.addArc(center: c, radius: R * inner, startAngle: a1, endAngle: a0, clockwise: true) } else { path.addLine(to: c) }
                        path.closeSubpath()
                    }
                case let .disc(radius):
                    path.addEllipse(in: CGRect(x: c.x - R * radius, y: c.y - R * radius, width: 2 * R * radius, height: 2 * R * radius))
                }
                if r.active {
                    ctx.addPath(path); ctx.setFillColor(highlight.withAlphaComponent(0.2).cgColor); ctx.fillPath(using: .evenOdd)
                }
                ctx.addPath(path); ctx.setStrokeColor((r.toggled ? highlight : text.withAlphaComponent(0.28)).cgColor)
                ctx.setLineWidth(r.toggled ? 9 : 3); ctx.strokePath()
                if let t = r.text {
                    let a = r.at.angle * .pi / 180, p = CGPoint(x: c.x + cos(a) * R * r.at.radius, y: c.y + sin(a) * R * r.at.radius)
                    let ring: Bool = { if case let .sector(from, to, _, _) = r.shape { return to - from >= 359.9 }; return false }()
                    let box = ring ? CGSize(width: s * 0.36, height: s * 0.1) : CGSize(width: s * 0.26, height: s * 0.16)
                    let rect = CGRect(x: p.x - box.width / 2, y: p.y - box.height / 2, width: box.width, height: box.height)
                    if let second = t.second {
                        fit(t.main, in: rect.offsetBy(dx: 0, dy: box.height * 0.22), weight: .bold, color: text)
                        fit(second, in: rect.insetBy(dx: box.width * 0.1, dy: box.height * 0.2).offsetBy(dx: 0, dy: -box.height * 0.42), weight: .semibold, color: text.withAlphaComponent(0.8))
                    } else {
                        fit(t.main, in: rect, weight: .bold, color: text)
                    }
                }
            }
            if let centre = f.centre {
                fit(centre, in: CGRect(x: s * 0.25, y: s * 0.4, width: s * 0.5, height: s * 0.2), weight: .bold, color: text.withAlphaComponent(0.85))
            }
            if let click = f.click {
                let r = CGRect(x: s * 0.33, y: s * 0.06, width: s * 0.34, height: s * 0.11)
                if f.clickActive { ctx.setFillColor(highlight.withAlphaComponent(0.3).cgColor); ctx.fill(r.insetBy(dx: -6, dy: -2)) }
                fit("⏎" + click.main, in: r, weight: .semibold, color: text.withAlphaComponent(0.9))
            }
        }
        cache[key] = img; trim()
        return img
    }

    private static func trim() { if cache.count > 400 { cache.removeAll(keepingCapacity: true) } }

    private static func draw(width: CGFloat, height: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Text as large as fits the box, centred, with a soft shadow so it reads on any colour.
    private static func fit(_ s: String, in box: CGRect, weight: NSFont.Weight, color: NSColor) {
        guard !s.isEmpty, box.width > 1, box.height > 1 else { return }
        var size = box.height
        var attrs: [NSAttributedString.Key: Any] = [:]
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.7); shadow.shadowBlurRadius = 4; shadow.shadowOffset = .zero
        var measured = CGSize.zero
        while size > 6 {
            attrs = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .shadow: shadow]
            measured = (s as NSString).size(withAttributes: attrs)
            if measured.width <= box.width && measured.height <= box.height * 1.25 { break }
            size *= 0.9
        }
        let p = CGPoint(x: box.midX - measured.width / 2, y: box.midY - measured.height / 2)
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}

extension NSColor {
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// The gyro steering wheel as a bar: the straight range in the middle, full lock at each end, and how far it's
/// turned now (filled from the centre, brighter once past the straight range).
enum WheelBarImage {
    static func draw(angle: Double, lock: Double, dead: Double, highlight: NSColor, width: CGFloat = 640, height: CGFloat = 64) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let track = CGRect(x: 8, y: height * 0.3, width: width - 16, height: height * 0.4)
        let mid = track.midX, half = track.width / 2, l = max(1, lock)
        func x(_ deg: Double) -> CGFloat { mid + CGFloat(max(-1, min(1, deg / l))) * half }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(CGPath(roundedRect: track.insetBy(dx: -4, dy: -4), cornerWidth: track.height / 2 + 4, cornerHeight: track.height / 2 + 4, transform: nil)); ctx.fillPath()
        // The straight range.
        let d = CGRect(x: x(-dead), y: track.minY, width: x(dead) - x(-dead), height: track.height)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.fill(d)
        // How far it's turned.
        let past = abs(angle) > dead
        let fill = CGRect(x: min(mid, x(angle)), y: track.minY, width: abs(x(angle) - mid), height: track.height)
        ctx.setFillColor((past ? highlight : highlight.withAlphaComponent(0.45)).cgColor); ctx.fill(fill)
        // Centre and the ends.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fill(CGRect(x: mid - 1.5, y: height * 0.18, width: 3, height: height * 0.64))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.fill(CGRect(x: track.minX, y: track.minY, width: 3, height: track.height)); ctx.fill(CGRect(x: track.maxX - 3, y: track.minY, width: 3, height: track.height))
        // Where it is.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: x(angle) - 3, y: height * 0.12, width: 6, height: height * 0.76))
        return ctx.makeImage()
    }
}
