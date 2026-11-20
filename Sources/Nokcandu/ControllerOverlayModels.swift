import AppKit
import SceneKit
import simd
import NokcanduCore

/// A controller for the overlay, built from simple shapes by a layout: an extruded body with chamfered edges, and
/// sticks, buttons, a d-pad, trackpads, bumpers and triggers as separate parts that press, tilt and light up.
/// A few thousand triangles each.
///
/// Axes are the controller's own, as its gyro reports them: x to the right, y out of its face, z towards the player.
/// The top edge (bumpers) is towards −z.
@MainActor
final class OverlayControllerModel {
    let root = SCNNode()
    let layout: OverlayLayout
    var aspect: Double { layout.aspect }

    private let bodyMaterial = SCNMaterial()
    private var buttonMaterials: [SCNMaterial] = []
    private var buttons: [PadProfiles.Input: [Button]] = [:]
    private var sticks: [Stick] = []
    private var pads: [Pad] = []
    private var triggers: [Trigger] = []
    private var buttonColor = NSColor.darkGray, highlight = NSColor.systemBlue

    private struct Button { let node: SCNNode; let material: SCNMaterial; let rest: SIMD3<Float>; let travel: SIMD3<Float> }
    private struct Stick { let side: Int; let pivot: SCNNode; let material: SCNMaterial; let rest: SIMD3<Float> }
    private struct Pad { let side: Int; let click: PadProfiles.Input; let disc: SCNNode; let dot: SCNNode; let material: SCNMaterial; let rest: SIMD3<Float>; let reach: SIMD2<Float>; let round: Bool; let turn: Float }
    private struct Trigger { let side: Int; let node: SCNNode; let material: SCNMaterial; let rest: SIMD3<Float>; let bar: SCNNode; let barMaterial: SCNMaterial }

    init(_ layout: OverlayLayout) {
        self.layout = layout
        bodyMaterial.lightingModel = .blinn
        bodyMaterial.specular.contents = NSColor(white: 0.25, alpha: 1)
        bodyMaterial.shininess = 0.3
        let body = SCNShape(path: layout.outline, extrusionDepth: CGFloat(layout.depth))
        body.chamferRadius = CGFloat(layout.chamfer)
        body.chamferMode = .both
        body.materials = [bodyMaterial]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.eulerAngles.x = -.pi / 2
        root.addChildNode(bodyNode)
        for part in layout.parts { add(part) }
        root.pivot = SCNMatrix4MakeTranslation(0, 0, CGFloat(layout.middle))
    }

    private var top: Float { layout.depth / 2 }

    private func material() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.specular.contents = NSColor(white: 0.3, alpha: 1)
        m.diffuse.contents = buttonColor
        buttonMaterials.append(m)
        return m
    }

    private func node(_ g: SCNGeometry, _ m: SCNMaterial, at p: SIMD3<Float>, turn: Float = 0) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g); n.simdPosition = p
        if turn != 0 { n.simdEulerAngles.y = turn }
        root.addChildNode(n)
        return n
    }

    private func add(_ part: OverlayLayout.Part) {
        switch part {
        case let .button(input, cap, at, turn):
            let (g, h) = geometry(cap)
            let p = SIMD3(at.x, top + h / 2, at.y), m = material()
            buttons[input, default: []].append(Button(node: node(g, m, at: p, turn: turn), material: m, rest: p, travel: SIMD3(0, -min(0.025, h * 0.4), 0)))
        case let .dpad(at, size):
            // A cross of four arms, each its own button.
            let arm = size * 0.36, w = size * 0.3
            let well = SCNCylinder(radius: CGFloat(size * 0.58), height: 0.02)
            _ = node(well, bodyMaterial, at: SIMD3(at.x, top + 0.005, at.y))
            for (input, d) in [(PadProfiles.Input.up, SIMD2<Float>(0, -1)), (.down, [0, 1]), (.left, [-1, 0]), (.right, [1, 0])] {
                let g = SCNBox(width: CGFloat(d.x == 0 ? w : arm), height: 0.06, length: CGFloat(d.x == 0 ? arm : w), chamferRadius: 0.02)
                let p = SIMD3(at.x + d.x * (arm / 2 + w * 0.1), top + 0.03, at.y + d.y * (arm / 2 + w * 0.1)), m = material()
                buttons[input, default: []].append(Button(node: node(g, m, at: p), material: m, rest: p, travel: SIMD3(0, -0.02, 0)))
            }
            let hub = SCNBox(width: CGFloat(w), height: 0.06, length: CGFloat(w), chamferRadius: 0.01)
            _ = node(hub, material(), at: SIMD3(at.x, top + 0.03, at.y))
        case let .stick(side, at, radius):
            let base = SCNCylinder(radius: CGFloat(radius * 1.25), height: 0.04)
            _ = node(base, bodyMaterial, at: SIMD3(at.x, top + 0.01, at.y))
            let pivot = SCNNode(); pivot.simdPosition = SIMD3(at.x, top + 0.02, at.y)
            root.addChildNode(pivot)
            let m = material()
            let shaft = SCNCylinder(radius: CGFloat(radius * 0.35), height: 0.14); shaft.materials = [m]
            let s = SCNNode(geometry: shaft); s.simdPosition = SIMD3(0, 0.07, 0); pivot.addChildNode(s)
            let cap = SCNCylinder(radius: CGFloat(radius), height: 0.07); cap.radialSegmentCount = 40; cap.materials = [m]
            let c = SCNNode(geometry: cap); c.simdPosition = SIMD3(0, 0.16, 0); pivot.addChildNode(c)
            let rim = SCNTorus(ringRadius: CGFloat(radius * 0.92), pipeRadius: CGFloat(radius * 0.1)); rim.materials = [m]
            let r = SCNNode(geometry: rim); r.simdPosition = SIMD3(0, 0.2, 0); pivot.addChildNode(r)
            sticks.append(Stick(side: side, pivot: pivot, material: m, rest: pivot.simdPosition))
        case let .pad(side, at, shape, turn, click):
            let m = material()
            let round: Bool, reach: SIMD2<Float>, g: SCNGeometry, well: SCNGeometry
            switch shape {
            case .round(let r):
                round = true; reach = .init(r * 0.85, r * 0.85)
                let d = SCNCylinder(radius: CGFloat(r), height: 0.03); d.radialSegmentCount = 64; g = d
                well = SCNCylinder(radius: CGFloat(r * 1.1), height: 0.02)
            case .rect(let w, let l):
                round = false; reach = .init(w / 2 * 0.9, l / 2 * 0.9)
                g = SCNBox(width: CGFloat(w), height: 0.03, length: CGFloat(l), chamferRadius: CGFloat(min(w, l) * 0.12))
                well = SCNBox(width: CGFloat(w * 1.08), height: 0.02, length: CGFloat(l + w * 0.08), chamferRadius: CGFloat(min(w, l) * 0.14))
            }
            _ = node(well, bodyMaterial, at: SIMD3(at.x, top + 0.005, at.y), turn: turn)
            let p = SIMD3(at.x, top + 0.02, at.y)
            let disc = node(g, m, at: p, turn: turn)
            let dot = SCNSphere(radius: CGFloat(min(reach.x, reach.y) * 0.16 + 0.02)); dot.segmentCount = 16
            let dm = SCNMaterial(); dm.lightingModel = .constant; dot.materials = [dm]
            let dn = SCNNode(geometry: dot); dn.isHidden = true; disc.addChildNode(dn)
            pads.append(Pad(side: side, click: click, disc: disc, dot: dn, material: m, rest: p, reach: reach, round: round, turn: turn))
        case let .bumper(input, at, width):
            let g = SCNBox(width: CGFloat(width), height: 0.13, length: 0.2, chamferRadius: 0.06)
            let p = SIMD3(at.x, 0.08, at.y), m = material()
            buttons[input, default: []].append(Button(node: node(g, m, at: p), material: m, rest: p, travel: SIMD3(0, 0, 0.03)))
        case let .trigger(side, at, width):
            // Raised behind the bumpers so they show from the front; a bar on top fills as they're pulled.
            let m = material()
            let g = SCNBox(width: CGFloat(width), height: 0.26, length: 0.3, chamferRadius: 0.09)
            let p = SIMD3(at.x, 0.2, at.y)
            let n = node(g, m, at: p)
            let bm = SCNMaterial(); bm.lightingModel = .constant
            let half = width * 0.41
            let bar = SCNBox(width: CGFloat(half * 2), height: 0.02, length: 0.1, chamferRadius: 0.01); bar.materials = [bm]
            let b = SCNNode(geometry: bar)
            b.pivot = SCNMatrix4MakeTranslation(CGFloat(side == 0 ? -half : half), 0, 0)   // grows from the outside in
            b.simdPosition = SIMD3(side == 0 ? -half : half, 0.135, 0.04)
            b.isHidden = true
            n.addChildNode(b)
            triggers.append(Trigger(side: side, node: n, material: m, rest: p, bar: b, barMaterial: bm))
        case let .grip(input, at, length, turn):
            // A grip or back button, on the outside edge where it can be seen from the front.
            let g = SCNBox(width: 0.08, height: 0.14, length: CGFloat(length), chamferRadius: 0.035)
            let m = material()
            let n = node(g, m, at: at, turn: turn)
            buttons[input, default: []].append(Button(node: n, material: m, rest: at, travel: SIMD3(at.x < 0 ? 0.03 : -0.03, 0, 0)))
        }
    }

    private func geometry(_ cap: OverlayLayout.Cap) -> (SCNGeometry, Float) {
        switch cap {
        case .round(let r): let c = SCNCylinder(radius: CGFloat(r), height: 0.07); c.radialSegmentCount = 32; return (c, 0.07)
        case .pill(let w, let l): return (SCNBox(width: CGFloat(w), height: 0.05, length: CGFloat(l), chamferRadius: CGFloat(min(w, l) / 2 * 0.95)), 0.05)
        case .square(let s): return (SCNBox(width: CGFloat(s), height: 0.05, length: CGFloat(s), chamferRadius: CGFloat(s * 0.2)), 0.05)
        }
    }

    func colors(body: NSColor, buttons: NSColor, highlight: NSColor) {
        bodyMaterial.diffuse.contents = body
        buttonColor = buttons; self.highlight = highlight
        for m in buttonMaterials { m.diffuse.contents = buttons; m.emission.contents = NSColor.black }
        for p in pads { p.dot.geometry?.firstMaterial?.diffuse.contents = highlight }
    }

    func show(_ i: ControllerOverlayInput) {
        for (input, list) in buttons {
            let down = i.buttons.contains(input)
            for b in list { light(b.material, down ? 1 : 0); b.node.simdPosition = b.rest + (down ? b.travel : .zero) }
        }
        // Sticks: up to 22° each way; lit while moved (more the further), fully when clicked.
        let maxTilt: Float = 22 * .pi / 180
        for s in sticks {
            let v = s.side == 0 ? i.leftStick : i.rightStick, click = i.buttons.contains(s.side == 0 ? .ls : .rs)
            s.pivot.simdEulerAngles = SIMD3(-v.y * maxTilt, 0, -v.x * maxTilt)
            s.pivot.simdPosition = s.rest + SIMD3(0, click ? -0.04 : 0, 0)
            let moved = min(1, simd_length(v))
            light(s.material, click ? 1 : moved > 0.08 ? 0.3 + 0.5 * moved : 0)
        }
        // Trackpads: a dot where the thumb is; a click presses the pad in and lights it.
        for p in pads {
            let touched = p.side == 0 ? i.leftTouch : i.rightTouch
            p.dot.isHidden = !touched
            if touched {
                var v = p.side == 0 ? i.leftPad : i.rightPad
                if p.round { let len = simd_length(v); if len > 1 { v /= len } } else { v = simd_clamp(v, SIMD2(repeating: -1), SIMD2(repeating: 1)) }
                // The dot is in the pad's own (turned) coordinates.
                p.dot.simdPosition = SIMD3(v.x * p.reach.x, 0.03, -v.y * p.reach.y)
            }
            let click = i.buttons.contains(p.click)
            light(p.material, click ? 1 : touched ? 0.25 : 0)
            p.disc.simdPosition = p.rest - SIMD3(0, click ? 0.02 : 0, 0)
        }
        // Triggers: part pulled, a soft colour and a bar filling across; fully pulled, solid and bright.
        for t in triggers {
            let v = max(0, min(1, t.side == 0 ? i.leftTrigger : i.rightTrigger)), full = v >= 0.99
            light(t.material, full ? 1 : v > 0.02 ? 0.2 + 0.4 * v : 0)
            t.node.simdPosition = t.rest + SIMD3(0, -0.08, 0.05) * v
            t.node.simdEulerAngles = SIMD3(-v * 0.3, 0, 0)
            t.bar.isHidden = v <= 0.02
            t.bar.simdScale = SIMD3(max(0.02, v), 1, 1)
            t.barMaterial.diffuse.contents = full ? NSColor.white : highlight
        }
    }

    /// 0 the button's own colour, 1 the highlight, glowing a little so it shows under any light.
    private func light(_ m: SCNMaterial, _ amount: Float) {
        let a = CGFloat(max(0, min(1, amount)))
        m.diffuse.contents = a == 0 ? buttonColor : buttonColor.blended(withFraction: a, of: highlight) ?? highlight
        m.emission.contents = a == 0 ? NSColor.black : highlight.blended(withFraction: 1 - a * 0.6, of: .black) ?? .black
    }
}

/// Where a controller's parts go. Positions are (x, z) on its face: x to the right, z towards the player.
struct OverlayLayout {
    enum Cap { case round(Float), pill(Float, Float), square(Float) }
    enum PadShape { case round(Float), rect(Float, Float) }
    enum Part {
        case button(PadProfiles.Input, Cap, SIMD2<Float>, turn: Float = 0)
        case dpad(SIMD2<Float>, size: Float)
        case stick(Int, SIMD2<Float>, radius: Float)
        case pad(Int, SIMD2<Float>, PadShape, turn: Float = 0, click: PadProfiles.Input)
        case bumper(PadProfiles.Input, SIMD2<Float>, width: Float)
        case trigger(Int, SIMD2<Float>, width: Float)
        /// x, y, z: on the body's edge.
        case grip(PadProfiles.Input, SIMD3<Float>, length: Float, turn: Float)
    }
    /// The body seen from above, x to the right and y away from the player.
    var outline: NSBezierPath
    var depth: Float = 0.36, chamfer: Float = 0.09
    /// Where it turns about (z), its middle.
    var middle: Float = 0.26
    /// Height ÷ width of the overlay that shows it.
    var aspect: Double = 0.66
    var parts: [Part]

    static func make(_ model: ControllerOverlaySettings.Model) -> OverlayLayout {
        switch model {
        case .automatic, .steam2015: steam2015
        case .steam2026: steam2026
        case .xbox: xbox
        case .switchPro: switchPro
        case .dualShock4: dualShock4
        }
    }

    /// A body outline from its right half: from the top middle to the bottom middle, each segment (end, control 1,
    /// control 2); the left half mirrors it.
    static func symmetric(from start: CGPoint, _ segments: [(CGPoint, CGPoint, CGPoint)]) -> NSBezierPath {
        let p = NSBezierPath(); p.flatness = 0.02
        p.move(to: start)
        for s in segments { p.curve(to: s.0, controlPoint1: s.1, controlPoint2: s.2) }
        var ends = [start] + segments.map(\.0)
        ends.removeLast()
        for (i, s) in segments.enumerated().reversed() {
            let to = ends[i]
            p.curve(to: CGPoint(x: -to.x, y: to.y), controlPoint1: CGPoint(x: -s.2.x, y: s.2.y), controlPoint2: CGPoint(x: -s.1.x, y: s.1.y))
        }
        p.close()
        return p
    }
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Steam Controller (2015)

    static let steam2015 = OverlayLayout(
        outline: symmetric(from: pt(0, 1.0), [
            (pt(1.5, 1.0), pt(0.5, 1.0), pt(1.0, 1.0)),
            (pt(2.02, 0.5), pt(1.88, 1.0), pt(2.02, 0.78)),
            (pt(1.86, -1.2), pt(2.06, -0.05), pt(2.04, -0.78)),
            (pt(1.34, -1.52), pt(1.76, -1.44), pt(1.56, -1.58)),
            (pt(0.9, -0.82), pt(1.1, -1.46), pt(0.98, -1.08)),
            (pt(0, -0.66), pt(0.74, -0.68), pt(0.36, -0.66)),
        ]),
        parts: [
            .pad(0, [-1.18, -0.34], .round(0.58), click: .touchpad),
            .pad(1, [1.18, -0.34], .round(0.58), click: .rs),        // its right pad's click is the right stick click
            .stick(0, [-0.66, 0.34], radius: 0.2),
            .button(.y, .round(0.095), [0.66, 0.12]), .button(.a, .round(0.095), [0.66, 0.56]),
            .button(.x, .round(0.095), [0.44, 0.34]), .button(.b, .round(0.095), [0.88, 0.34]),
            .button(.back, .round(0.06), [-0.3, 0.02]), .button(.start, .round(0.06), [0.3, 0.02]),
            .button(.guide, .round(0.15), [0, -0.3]),
            .bumper(.lb, [-1.28, -1.02], width: 0.95), .bumper(.rb, [1.28, -1.02], width: 0.95),
            .trigger(0, [-1.28, -1.2], width: 0.8), .trigger(1, [1.28, -1.2], width: 0.8),
            .grip(.paddle2, [-1.92, -0.02, 0.62], length: 0.6, turn: -0.32), .grip(.paddle1, [1.92, -0.02, 0.62], length: 0.6, turn: 0.32),
        ])

    // MARK: Steam Controller (2026)

    /// From the editor's picture of it (`Steam2026PictureGeometry`): the same outline and landmarks.
    static var steam2026: OverlayLayout {
        let w: CGFloat = 4.2, h = w / 1.38
        let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let path = NSBezierPath(cgPath: Steam2026PictureGeometry.shellPath(in: r))
        path.transform(using: AffineTransform(scaleByX: 1, byY: -1))      // its y is down; ours is away from the player
        path.flatness = 0.02
        func at(_ fx: Float, _ fy: Float) -> SIMD2<Float> { [(fx - 0.5) * Float(w), (fy - 0.5) * Float(h)] }
        let reach = Float(w) * 0.055, d = at(0.185, 0.18), f = at(0.815, 0.18)
        let pad = Float(w) * 0.23, stick = Float(w) * 27 / 420
        func edge(_ p: SIMD2<Float>) -> SIMD3<Float> { [p.x, -0.02, p.y] }
        return OverlayLayout(outline: path, middle: 0, aspect: 0.74, parts: [
            .dpad(d, size: reach * 2.3),
            .button(.y, .round(0.1), f + [0, -reach]), .button(.a, .round(0.1), f + [0, reach]),
            .button(.x, .round(0.1), f + [-reach, 0]), .button(.b, .round(0.1), f + [reach, 0]),
            .stick(0, at(0.35, 0.26), radius: stick), .stick(1, at(0.65, 0.26), radius: stick),
            .pad(0, at(0.305, 0.55), .rect(pad, pad), turn: -10 * .pi / 180, click: .touchpad),
            .pad(1, at(0.695, 0.55), .rect(pad, pad), turn: 10 * .pi / 180, click: .rpclick),
            .button(.back, .pill(0.18, 0.09), at(0.32, 0.087)), .button(.start, .pill(0.18, 0.09), at(0.68, 0.087)),
            .button(.guide, .round(0.13), at(0.5, 0.18)), .button(.misc, .pill(0.2, 0.1), at(0.5, 0.55)),
            .bumper(.lb, at(0.22, -0.02), width: 0.95), .bumper(.rb, at(0.78, -0.02), width: 0.95),
            .trigger(0, at(0.22, -0.08), width: 0.85), .trigger(1, at(0.78, -0.08), width: 0.85),
            // Back buttons, on the edge where the editor's picture has them: L4/R4 higher, L5/R5 lower.
            .grip(.paddle2, edge(at(0.055, 0.66)), length: 0.42, turn: -0.2),
            .grip(.paddle1, edge(at(0.945, 0.66)), length: 0.42, turn: 0.2),
            .grip(.paddle4, edge(at(0.12, 0.91)), length: 0.38, turn: -0.55),
            .grip(.paddle3, edge(at(0.88, 0.91)), length: 0.38, turn: 0.55),
        ])
    }

    // MARK: Xbox

    static let xbox = OverlayLayout(
        outline: symmetric(from: pt(0, 0.98), [
            (pt(1.3, 1.06), pt(0.55, 0.98), pt(1.0, 1.08)),
            (pt(1.98, 0.42), pt(1.72, 1.03), pt(1.97, 0.78)),
            (pt(1.78, -1.3), pt(2.0, -0.15), pt(2.02, -0.92)),
            (pt(1.22, -1.58), pt(1.62, -1.56), pt(1.42, -1.66)),
            (pt(0.78, -0.78), pt(1.0, -1.48), pt(0.95, -0.98)),
            (pt(0, -0.62), pt(0.6, -0.62), pt(0.3, -0.62)),
        ]),
        parts: [
            .stick(0, [-1.18, -0.38], radius: 0.22), .stick(1, [0.62, 0.25], radius: 0.22),
            .dpad([-0.62, 0.25], size: 0.46),
            .button(.y, .round(0.11), [1.18, -0.62]), .button(.a, .round(0.11), [1.18, -0.14]),
            .button(.x, .round(0.11), [0.94, -0.38]), .button(.b, .round(0.11), [1.42, -0.38]),
            .button(.guide, .round(0.17), [0, -0.68]),
            .button(.back, .round(0.07), [-0.36, -0.3]), .button(.start, .round(0.07), [0.36, -0.3]),
            .button(.misc, .pill(0.13, 0.07), [0, -0.1]),
            .bumper(.lb, [-1.25, -1.08], width: 1.0), .bumper(.rb, [1.25, -1.08], width: 1.0),
            .trigger(0, [-1.25, -1.26], width: 0.8), .trigger(1, [1.25, -1.26], width: 0.8),
            // Elite back paddles, where a controller has them.
            .grip(.paddle2, [-1.86, -0.02, 0.55], length: 0.5, turn: -0.3), .grip(.paddle1, [1.86, -0.02, 0.55], length: 0.5, turn: 0.3),
        ])

    // MARK: Switch Pro Controller

    static let switchPro = OverlayLayout(
        outline: symmetric(from: pt(0, 0.95), [
            (pt(1.25, 1.05), pt(0.55, 0.95), pt(0.95, 1.08)),
            (pt(1.95, 0.35), pt(1.7, 1.03), pt(1.98, 0.72)),
            (pt(1.7, -1.38), pt(1.95, -0.25), pt(2.0, -1.05)),
            (pt(1.15, -1.6), pt(1.55, -1.6), pt(1.32, -1.68)),
            (pt(0.75, -0.8), pt(0.95, -1.5), pt(0.9, -1.0)),
            (pt(0, -0.7), pt(0.55, -0.7), pt(0.3, -0.7)),
        ]),
        depth: 0.4, chamfer: 0.12,
        parts: [
            .stick(0, [-1.18, -0.35], radius: 0.22), .stick(1, [0.6, 0.28], radius: 0.22),
            .dpad([-0.6, 0.28], size: 0.44),
            // Positions, not letters: top, bottom, left, right as the remapper names them.
            .button(.y, .round(0.11), [1.18, -0.6]), .button(.a, .round(0.11), [1.18, -0.1]),
            .button(.x, .round(0.11), [0.93, -0.35]), .button(.b, .round(0.11), [1.43, -0.35]),
            .button(.back, .pill(0.13, 0.05), [-0.42, -0.72]), .button(.start, .round(0.065), [0.42, -0.72]),
            .button(.misc, .square(0.1), [-0.32, -0.4]), .button(.guide, .round(0.09), [0.32, -0.4]),
            .bumper(.lb, [-1.22, -1.06], width: 1.0), .bumper(.rb, [1.22, -1.06], width: 1.0),
            .trigger(0, [-1.22, -1.24], width: 0.8), .trigger(1, [1.22, -1.24], width: 0.8),
        ])

    // MARK: DualShock 4 / DualSense

    static let dualShock4 = OverlayLayout(
        outline: symmetric(from: pt(0, 0.75), [
            (pt(1.05, 0.8), pt(0.4, 0.75), pt(0.8, 0.8)),
            (pt(1.55, 1.02), pt(1.25, 0.8), pt(1.35, 1.02)),
            (pt(2.0, 0.55), pt(1.85, 1.02), pt(2.02, 0.85)),
            (pt(1.9, -1.45), pt(2.0, 0.0), pt(2.1, -1.1)),
            (pt(1.4, -1.65), pt(1.8, -1.68), pt(1.55, -1.72)),
            (pt(0.85, -0.75), pt(1.2, -1.55), pt(1.0, -0.95)),
            (pt(0, -0.55), pt(0.65, -0.55), pt(0.3, -0.55)),
        ]),
        middle: 0.3,
        parts: [
            .dpad([-1.3, -0.3], size: 0.46),
            .button(.y, .round(0.105), [1.3, -0.53]), .button(.a, .round(0.105), [1.3, -0.07]),
            .button(.x, .round(0.105), [1.07, -0.3]), .button(.b, .round(0.105), [1.53, -0.3]),
            .stick(0, [-0.6, 0.35], radius: 0.22), .stick(1, [0.6, 0.35], radius: 0.22),
            .pad(0, [0, -0.42], .rect(1.5, 0.6), click: .touchpad),
            .button(.back, .pill(0.07, 0.15), [-0.9, -0.62]), .button(.start, .pill(0.07, 0.15), [0.9, -0.62]),
            .button(.guide, .round(0.1), [0, 0.25]),
            .bumper(.lb, [-1.5, -1.08], width: 0.8), .bumper(.rb, [1.5, -1.08], width: 0.8),
            .trigger(0, [-1.5, -1.26], width: 0.7), .trigger(1, [1.5, -1.26], width: 0.7),
            .grip(.paddle2, [-1.95, -0.02, 0.6], length: 0.45, turn: -0.2), .grip(.paddle1, [1.95, -0.02, 0.6], length: 0.45, turn: 0.2),
        ])
}
