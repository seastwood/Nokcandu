import Foundation
import CoreGraphics

/// Physical controls and bounded callout lanes for the 2026 controller. Fractions describe the body,
/// not the entire canvas, so the outer annotation gutters and gyro never cover the hardware.
public struct Steam2026PictureGeometry {
    public enum Control: String, CaseIterable, Sendable {
        case lt, rt, ltfull, rtfull, lb, rb, up, down, left, right, y, a, x, b
        case back, start, guide, misc, paddle1, paddle2, paddle3, paddle4
        public var title: String {
            switch self {
            case .up: "▲"; case .down: "▼"; case .left: "◀"; case .right: "▶"
            case .lt: "LT"; case .rt: "RT"; case .ltfull, .rtfull: "full"; case .lb: "LB"; case .rb: "RB"
            case .y: "Y"; case .a: "A"; case .x: "X"; case .b: "B"
            case .back: "View"; case .start: "Menu"; case .guide: "Steam"; case .misc: "QAM"
            case .paddle1: "R4"; case .paddle2: "L4"; case .paddle3: "R5"; case .paddle4: "L5"
            }
        }
    }
    public enum Part: Hashable, Sendable { case button(Control), stick(Int), trackpad(Int), gyro, rumble }
    public let body: CGRect
    public let scale: CGFloat
    public static func height(for width: CGFloat) -> CGFloat { width * 0.9 }
    public init(width: CGFloat) {
        let w = max(1, width) * 0.74
        body = CGRect(x: (width - w) / 2, y: w * 0.31, width: w, height: w / 1.38)
        scale = w / 420
    }
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
    }
    private func rect(_ center: CGPoint, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
    public func center(_ c: Control) -> CGPoint {
        // Front-photo landmarks, measured against the shell (excluding shoulder protrusions).
        let d = point(0.185, 0.18), f = point(0.815, 0.18), reach = body.width * 0.055
        switch c {
        case .up: return CGPoint(x: d.x, y: d.y - reach)
        case .down: return CGPoint(x: d.x, y: d.y + reach)
        case .left: return CGPoint(x: d.x - reach, y: d.y)
        case .right: return CGPoint(x: d.x + reach, y: d.y)
        case .y: return CGPoint(x: f.x, y: f.y - reach)
        case .a: return CGPoint(x: f.x, y: f.y + reach)
        case .x: return CGPoint(x: f.x - reach, y: f.y)
        case .b: return CGPoint(x: f.x + reach, y: f.y)
        case .back: return point(0.32, 0.087)
        case .start: return point(0.68, 0.087)
        case .guide: return point(0.5, 0.18)
        case .misc: return point(0.5, 0.55)
        case .paddle2: return point(0.055, 0.66)
        case .paddle1: return point(0.945, 0.66)
        case .paddle4: return point(0.12, 0.91)
        case .paddle3: return point(0.88, 0.91)
        case .lt: return point(0.22, -0.35)
        case .rt: return point(0.78, -0.35)
        case .ltfull: return point(0.10, -0.35)
        case .rtfull: return point(0.90, -0.35)
        case .lb: return point(0.22, -0.17)
        case .rb: return point(0.78, -0.17)
        }
    }
    public func controlRect(_ c: Control) -> CGRect {
        let width: CGFloat, height: CGFloat
        switch c {
        case .lt, .rt, .ltfull, .rtfull, .lb, .rb: width = 46; height = 28
        case .guide: width = 30; height = 30
        case .back, .start: width = 30; height = 16
        case .misc: width = 38; height = 18
        default: width = 24; height = 24
        }
        return rect(center(c), width * scale, height * scale)
    }
    public func captionRect(_ c: Control) -> CGRect {
        let p = center(c), control = controlRect(c), gap = 5 * scale
        var width = body.width * 0.18, height = body.width * 0.067
        switch c {
        case .lt, .rt, .lb, .rb: width = body.width * 0.16; height = body.width * 0.03
        case .back, .start: width = body.width * 0.115; height = body.width * 0.03
        case .guide: width = body.width * 0.14
        case .misc: width = body.width * 0.115
        case .a, .down: height = body.width * 0.03
        case .paddle1, .paddle2: width = body.width * 0.20
        default: break
        }
        if c == .right || c == .x {
            // The real inner buttons sit above the sticks. Keep their callouts in that gap instead of
            // spreading the hardware apart to make room for text.
            width = body.width * 0.14; height = body.width * 0.026
            let x = c == .right ? control.maxX + gap + width / 2 : control.minX - gap - width / 2
            return rect(CGPoint(x: x, y: stickRect(0).minY - gap - height / 2), width, height)
        }
        if c == .back || c == .start {
            return rect(CGPoint(x: p.x + (c == .back ? 0.02 : -0.02) * body.width,
                                y: control.minY - gap - height / 2), width, height)
        }
        switch c {
        case .up, .y, .back, .start:
            return rect(CGPoint(x: p.x, y: control.minY - gap - height / 2), width, height)
        case .left, .x, .ltfull:
            return rect(CGPoint(x: control.minX - gap - width / 2, y: p.y), width, height)
        case .right, .b, .rtfull:
            return rect(CGPoint(x: control.maxX + gap + width / 2, y: p.y), width, height)
        default:
            return rect(CGPoint(x: p.x, y: control.maxY + gap + height / 2), width, height)
        }
    }
    public func stickRect(_ side: Int) -> CGRect { rect(point(side == 0 ? 0.35 : 0.65, 0.26), 54 * scale, 54 * scale) }
    public func stickCaptionRect(_ side: Int) -> CGRect {
        rect(point(side == 0 ? 0.02 : 0.98, 0.45), body.width * 0.24, body.width * 0.095)
    }
    public static func padAngle(_ side: Int) -> Double { side == 0 ? 10 : -10 }
    public func padRect(_ side: Int) -> CGRect { rect(point(side == 0 ? 0.305 : 0.695, 0.55), body.width * 0.23, body.width * 0.23) }
    public func padBounds(_ side: Int) -> CGRect {
        let p = padRect(side), a = abs(Self.padAngle(side)) * .pi / 180
        let reach = p.width * (cos(a) + sin(a))
        return rect(CGPoint(x: p.midX, y: p.midY), reach, reach)
    }
    public func padCaptionRect(_ side: Int) -> CGRect {
        let p = padBounds(side), height = body.width * 0.105
        return rect(CGPoint(x: p.midX, y: p.maxY + 5 * scale + height / 2), body.width * 0.265, height)
    }
    /// Between the handles, under the inner cutout (0.774 of the body) and the trackpads' captions, with Rumble right
    /// below it. Both the same size, like the other controllers' pair.
    public var gyro: CGRect {
        let top = max(body.minY + body.height * 0.774 + 8 * scale, max(padCaptionRect(0).maxY, padCaptionRect(1).maxY) + 4 * scale)
        return CGRect(x: body.midX - 46 * scale, y: top, width: 92 * scale, height: 28 * scale)
    }
    public var rumble: CGRect { gyro.offsetBy(dx: 0, dy: gyro.height + 6 * scale) }

    /// Shared by the renderer and containment checks, including the shallow, nearly flat inner cutout.
    public static func shellPath(in r: CGRect) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        let path = CGMutablePath()
        path.move(to: p(0.24, 0.008))
        path.addQuadCurve(to: p(0.76, 0.008), control: p(0.5, -0.008))
        path.addCurve(to: p(0.93, 0.17), control1: p(0.88, 0.008), control2: p(0.905, 0.05))
        path.addCurve(to: p(1, 0.78), control1: p(0.97, 0.33), control2: p(1, 0.60))
        path.addCurve(to: p(0.88, 0.997), control1: p(1, 0.91), control2: p(0.97, 0.98))
        path.addCurve(to: p(0.745, 0.805), control1: p(0.79, 1.025), control2: p(0.77, 0.93))
        path.addQuadCurve(to: p(0.69, 0.774), control: p(0.73, 0.774))
        path.addLine(to: p(0.31, 0.774))
        path.addQuadCurve(to: p(0.255, 0.805), control: p(0.27, 0.774))
        path.addCurve(to: p(0.12, 0.997), control1: p(0.23, 0.93), control2: p(0.21, 1.025))
        path.addCurve(to: p(0, 0.78), control1: p(0.03, 0.98), control2: p(0, 0.91))
        path.addCurve(to: p(0.07, 0.17), control1: p(0, 0.60), control2: p(0.03, 0.33))
        path.addCurve(to: p(0.24, 0.008), control1: p(0.095, 0.05), control2: p(0.12, 0.008))
        path.closeSubpath()
        return path
    }
}
