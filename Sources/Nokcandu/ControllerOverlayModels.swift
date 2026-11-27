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
    private let panelMaterial = SCNMaterial()
    /// Mapping labels lying on the parts (hidden until mappings are shown), and what they show now.
    private var capLabels: [PadProfiles.Input: [(node: SCNNode, aspect: CGFloat)]] = [:]
    private var padLabels: [Int: SCNNode] = [:]
    private var stickLabels: [Int: (node: SCNNode, aspect: CGFloat)] = [:]
    private var shownMappings: OverlayMappings?
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
        if let panel = layout.panel {
            panelMaterial.lightingModel = .blinn
            panelMaterial.specular.contents = NSColor(white: 0.2, alpha: 1)
            let slab = SCNShape(path: panel, extrusionDepth: 0.03)
            slab.chamferRadius = 0.012; slab.chamferMode = .front
            slab.materials = [panelMaterial]
            let n = SCNNode(geometry: slab)
            n.eulerAngles.x = -.pi / 2
            n.simdPosition = SIMD3(0, layout.depth / 2 + 0.006, 0)
            root.addChildNode(n)
        }
        moved = Set(layout.parts.compactMap { if case let .label(i, _, _, _) = $0 { return i }; return nil })
        for part in layout.parts { add(part) }
        root.pivot = SCNMatrix4MakeTranslation(0, 0, CGFloat(layout.middle))
    }

    private var top: Float { layout.depth / 2 }
    /// Inputs whose mapping is written beside their button rather than on it.
    private(set) var moved: Set<PadProfiles.Input> = []

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
            let n = node(g, m, at: p, turn: turn), size = capSize(cap)
            buttons[input, default: []].append(Button(node: n, material: m, rest: p, travel: SIMD3(0, -min(0.025, h * 0.4), 0)))
            if !moved.contains(input) { capLabels[input, default: []].append(labelPlane(size.x * 0.96, size.y * 0.96, on: n, y: h / 2 + 0.003)) }
        case let .dpad(at, size):
            // A cross of four arms, each its own button.
            let arm = size * 0.36, w = size * 0.3
            let well = SCNCylinder(radius: CGFloat(size * 0.58), height: 0.02)
            _ = node(well, bodyMaterial, at: SIMD3(at.x, top + 0.005, at.y))
            for (input, d) in [(PadProfiles.Input.up, SIMD2<Float>(0, -1)), (.down, [0, 1]), (.left, [-1, 0]), (.right, [1, 0])] {
                let g = SCNBox(width: CGFloat(d.x == 0 ? w : arm), height: 0.06, length: CGFloat(d.x == 0 ? arm : w), chamferRadius: 0.02)
                let p = SIMD3(at.x + d.x * (arm / 2 + w * 0.1), top + 0.03, at.y + d.y * (arm / 2 + w * 0.1)), m = material()
                let n = node(g, m, at: p)
                buttons[input, default: []].append(Button(node: n, material: m, rest: p, travel: SIMD3(0, -0.02, 0)))
                if !moved.contains(input) { capLabels[input, default: []].append(labelPlane(d.x == 0 ? w : arm, d.x == 0 ? arm : w, on: n, y: 0.033)) }
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
            stickLabels[side] = labelPlane(radius * 1.7, radius * 1.7, on: c, y: 0.038)
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
            // Above the centre panel where they overlap it, so a press never sinks the face into it.
            let lift: Float = layout.panel == nil ? 0 : 0.016
            _ = node(well, bodyMaterial, at: SIMD3(at.x, top + 0.005 + lift, at.y), turn: turn)
            let p = SIMD3(at.x, top + 0.02 + lift, at.y)
            let disc = node(g, m, at: p, turn: turn)
            let dot = SCNSphere(radius: CGFloat(min(reach.x, reach.y) * 0.16 + 0.02)); dot.segmentCount = 16
            let dm = SCNMaterial(); dm.lightingModel = .constant; dot.materials = [dm]
            let dn = SCNNode(geometry: dot); dn.isHidden = true; disc.addChildNode(dn)
            let face: SIMD2<Float> = { switch shape { case .round(let r): SIMD2(r * 2, r * 2); case .rect(let w, let l): SIMD2(w, l) } }()
            padLabels[side] = labelPlane(face.x, face.y, on: disc, y: 0.017).node
            pads.append(Pad(side: side, click: click, disc: disc, dot: dn, material: m, rest: p, reach: reach, round: round, turn: turn))
        case let .bumper(input, at, width):
            let g = SCNBox(width: CGFloat(width), height: 0.13, length: 0.2, chamferRadius: 0.06)
            let p = SIMD3(at.x, 0.08, at.y), m = material()
            let n = node(g, m, at: p)
            buttons[input, default: []].append(Button(node: n, material: m, rest: p, travel: SIMD3(0, 0, 0.03)))
            if !moved.contains(input) { capLabels[input, default: []].append(labelPlane(width * 0.7, 0.17, on: n, y: 0.068)) }
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
            capLabels[side == 0 ? .lt : .rt, default: []].append(labelPlane(width * 0.62, 0.16, on: n, y: 0.137, z: -0.07))
        case let .grip(input, at, length, turn):
            // A grip or back button, on the outside edge where it can be seen from the front.
            let g = SCNBox(width: 0.13, height: 0.16, length: CGFloat(length), chamferRadius: 0.05)
            let m = material()
            let n = node(g, m, at: at, turn: turn)
            buttons[input, default: []].append(Button(node: n, material: m, rest: at, travel: SIMD3(at.x < 0 ? 0.03 : -0.03, 0, 0)))
            if !moved.contains(input) { capLabels[input, default: []].append(labelPlane(0.34, max(0.2, length * 0.8), on: n, y: 0.074)) }
        case let .label(input, at, width, length):
            let n = SCNNode(); n.simdPosition = SIMD3(at.x, top + at.y, at.z)
            root.addChildNode(n)
            capLabels[input, default: []].append(labelPlane(width, length, on: n, y: 0))
        }
    }

    /// A flat label lying on a part's top (texture up = away from the player), drawn over it and unlit.
    private func labelPlane(_ width: Float, _ length: Float, on parent: SCNNode, y: Float, z: Float = 0) -> (node: SCNNode, aspect: CGFloat) {
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(length))
        let m = SCNMaterial(); m.lightingModel = .constant; m.writesToDepthBuffer = false; m.blendMode = .alpha
        m.diffuse.contents = NSColor.clear
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.simdEulerAngles.x = -.pi / 2
        n.simdPosition = SIMD3(0, y, z)
        n.renderingOrder = 20
        n.isHidden = true
        parent.addChildNode(n)
        return (n, CGFloat(width / max(0.001, length)))
    }
    private func capSize(_ cap: OverlayLayout.Cap) -> SIMD2<Float> {
        switch cap { case .round(let r): SIMD2(r * 2, r * 2); case .pill(let w, let l): SIMD2(w, l); case .square(let s): SIMD2(s, s) }
    }

    /// Each trackpad's click input, by side.
    var padClicks: [(Int, PadProfiles.Input)] { pads.map { ($0.side, $0.click) } }

    /// Shows what each part does (nil hides the labels). Only labels that changed are redrawn.
    func showMappings(_ m: OverlayMappings?) {
        guard m != shownMappings else { return }
        shownMappings = m
        func set(_ n: SCNNode, _ image: CGImage?) {
            n.isHidden = image == nil
            if let image { n.geometry?.firstMaterial?.diffuse.contents = image }
        }
        for (input, list) in capLabels {
            let cap = m?.buttons[input]
            for l in list { set(l.node, cap.flatMap { OverlayLabelImages.cap($0, aspect: l.aspect, highlight: highlight) }) }
        }
        for (side, n) in padLabels { set(n, m?.pads[side].flatMap { OverlayLabelImages.pad($0, highlight: highlight) }) }
        for (side, l) in stickLabels { set(l.node, m?.sticks[side].flatMap { OverlayLabelImages.cap($0, aspect: l.aspect, highlight: highlight) }) }
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
        panelMaterial.diffuse.contents = body.blended(withFraction: 0.12, of: .white) ?? body
        let highlightChanged = self.highlight != highlight
        buttonColor = buttons; self.highlight = highlight
        if highlightChanged, let m = shownMappings { shownMappings = nil; showMappings(m) }
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
            p.disc.simdPosition = p.rest - SIMD3(0, click ? 0.008 : 0, 0)
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
        /// Where an input's mapping is written when its button is too small or hidden to hold it: on the body
        /// (x, height above the face, z), width by length. The button itself then carries no label.
        case label(PadProfiles.Input, SIMD3<Float>, width: Float, length: Float)
    }
    /// The body seen from above, x to the right and y away from the player.
    var outline: NSBezierPath
    /// A lighter panel raised a little on the face (the original Steam Controller's centre), same coordinates.
    var panel: NSBezierPath? = nil
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

    /// The original Steam Controller's silhouette seen from the front (x right, y away from the player), and its
    /// lighter centre panel. Shape from PadSight's 2015 theme generator (github.com/80sFauxstalgia/padsight, MIT,
    /// itself based on VSCView by John Klein): its picture coordinates scaled to the overlay's units.
    static let steam2015Body: [(CGFloat, CGFloat)] = [
        (-0.262, 0.999), (-0.596, 0.997), (-0.873, 0.991), (-1.092, 0.983), (-1.258, 0.972), (-1.377, 0.955), (-1.471, 0.927), (-1.541, 0.885),
        (-1.595, 0.828), (-1.637, 0.750), (-1.679, 0.643), (-1.722, 0.508), (-1.766, 0.354), (-1.812, 0.184), (-1.856, 0.002), (-1.897, -0.189),
        (-1.933, -0.377), (-1.964, -0.562), (-1.991, -0.745), (-2.011, -0.922), (-2.020, -1.077), (-2.016, -1.215), (-1.996, -1.346), (-1.958, -1.467),
        (-1.902, -1.573), (-1.829, -1.661), (-1.742, -1.727), (-1.644, -1.773), (-1.543, -1.795), (-1.443, -1.794), (-1.356, -1.773), (-1.279, -1.732),
        (-1.211, -1.674), (-1.151, -1.601), (-1.094, -1.513), (-1.038, -1.415), (-0.982, -1.314), (-0.927, -1.214), (-0.874, -1.124), (-0.822, -1.044),
        (-0.768, -0.984), (-0.705, -0.941), (-0.611, -0.912), (-0.480, -0.895), (-0.291, -0.885), (-0.058, -0.882), (0.175, -0.883), (0.393, -0.889),
        (0.553, -0.902), (0.662, -0.925), (0.740, -0.961), (0.795, -1.012), (0.848, -1.082), (0.900, -1.168), (0.954, -1.263), (1.010, -1.365),
        (1.066, -1.464), (1.122, -1.559), (1.181, -1.639), (1.244, -1.705), (1.316, -1.754), (1.398, -1.786), (1.492, -1.797), (1.594, -1.787),
        (1.693, -1.753), (1.787, -1.697), (1.868, -1.619), (1.933, -1.522), (1.979, -1.409), (2.008, -1.281), (2.020, -1.147), (2.017, -1.002),
        (2.003, -0.836), (1.978, -0.654), (1.949, -0.470), (1.915, -0.283), (1.877, -0.094), (1.834, 0.094), (1.790, 0.270), (1.744, 0.433),
        (1.700, 0.578), (1.658, 0.700), (1.616, 0.793), (1.570, 0.859), (1.508, 0.908), (1.427, 0.942), (1.321, 0.965), (1.182, 0.978),
        (0.989, 0.988), (0.742, 0.994), (0.436, 0.998), (0.087, 1.000)
    ]
    static let steam2015Panel: [(CGFloat, CGFloat)] = [
        (-0.279, 0.601), (-0.631, 0.598), (-0.902, 0.583), (-1.101, 0.543), (-1.258, 0.436), (-1.355, 0.274), (-1.338, 0.098), (-1.231, -0.087),
        (-1.105, -0.271), (-0.972, -0.443), (-0.865, -0.581), (-0.778, -0.684), (-0.698, -0.749), (-0.595, -0.782), (-0.378, -0.799), (-0.076, -0.802),
        (0.227, -0.801), (0.501, -0.793), (0.661, -0.768), (0.737, -0.721), (0.820, -0.637), (0.915, -0.517), (1.036, -0.361), (1.171, -0.179),
        (1.287, 0.005), (1.361, 0.188), (1.321, 0.357), (1.185, 0.498), (1.007, 0.572), (0.777, 0.592), (0.465, 0.601), (0.093, 0.601)
    ]

    /// A closed outline through points (x, y away from the player).
    static func polygon(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let p = NSBezierPath(); p.flatness = 0.02
        guard let first = pts.first else { return p }
        p.move(to: pt(first.0, first.1))
        for q in pts.dropFirst() { p.line(to: pt(q.0, q.1)) }
        p.close()
        return p
    }

    /// Proportions from the real controller (the PadSight outline): big recessed pads in the upper corners, the
    /// Steam button between them with the two arrow keys, the stick lower left and ABXY lower right on the lighter
    /// centre panel, handles flaring out around a broad arch, grips (back paddles) on the handles' outsides.
    static let steam2015 = OverlayLayout(
        outline: polygon(steam2015Body), panel: polygon(steam2015Panel), middle: 0.42, aspect: 0.74,
        parts: [
            .pad(0, [-1.117, -0.242], .round(0.456), click: .touchpad),
            .pad(1, [1.117, -0.242], .round(0.456), click: .rs),        // its right pad's click is the right stick click
            .stick(0, [-0.442, 0.386], radius: 0.2),
            .button(.y, .round(0.1), [0.456, 0.13]), .button(.a, .round(0.1), [0.456, 0.586]),
            .button(.x, .round(0.1), [0.228, 0.358]), .button(.b, .round(0.1), [0.684, 0.358]),
            .button(.back, .pill(0.21, 0.115), [-0.354, -0.266]), .button(.start, .pill(0.21, 0.115), [0.354, -0.266]),
            .button(.guide, .round(0.15), [0, -0.35]),
            .bumper(.lb, [-1.2, -1.0], width: 1.0), .bumper(.rb, [1.2, -1.0], width: 1.0),
            .trigger(0, [-1.13, -1.16], width: 0.82), .trigger(1, [1.13, -1.16], width: 0.82),
            .grip(.paddle2, [-2.04, 0.06, 1.0], length: 0.55, turn: -0.07), .grip(.paddle1, [2.04, 0.06, 1.0], length: 0.55, turn: 0.07),
            // Mappings written where they read: the bumpers' on the face's upper corners, Back and Start above
            // their buttons, the stick click below the stick, the grips beside the handles.
            .label(.lb, [-1.2, 0.004, -0.84], width: 0.7, length: 0.19), .label(.rb, [1.2, 0.004, -0.84], width: 0.7, length: 0.19),
            .label(.back, [-0.37, 0.026, -0.44], width: 0.36, length: 0.18), .label(.start, [0.37, 0.026, -0.44], width: 0.36, length: 0.18),
            .label(.ls, [-0.442, 0.026, 0.67], width: 0.5, length: 0.18),
            .label(.paddle2, [-1.72, 0.004, 1.02], width: 0.36, length: 0.14), .label(.paddle1, [1.72, 0.004, 1.02], width: 0.36, length: 0.14),
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
            // Labels beside the small parts: bumpers on the upper corners, View and Menu beside, QAM below.
            // Out in the corners, clear of the D-pad's top label and the Y button.
            .label(.lb, [at(0.1, 0.1).x, 0.004, at(0.1, 0.1).y], width: 0.44, length: 0.16),
            .label(.rb, [at(0.9, 0.1).x, 0.004, at(0.9, 0.1).y], width: 0.44, length: 0.16),
            .label(.back, [at(0.32, 0.087).x + 0.24, 0.004, at(0.32, 0.087).y], width: 0.26, length: 0.14),
            .label(.start, [at(0.68, 0.087).x - 0.24, 0.004, at(0.68, 0.087).y], width: 0.26, length: 0.14),
            .label(.misc, [0, 0.004, at(0.5, 0.55).y + 0.16], width: 0.3, length: 0.14),
            .label(.paddle2, [at(0.1, 0.66).x + 0.12, 0.004, at(0.1, 0.66).y], width: 0.3, length: 0.14),
            .label(.paddle1, [at(0.9, 0.66).x - 0.12, 0.004, at(0.9, 0.66).y], width: 0.3, length: 0.14),
        ] + dpadLabels(d, size: reach * 2.3))
    }

    /// A D-pad's labels just outside its arms (the arms are too narrow to write on).
    static func dpadLabels(_ c: SIMD2<Float>, size: Float) -> [Part] {
        let d = size * 0.86, w = size * 0.5, l = size * 0.32
        return [.label(.up, [c.x, 0.02, c.y - d], width: w, length: l), .label(.down, [c.x, 0.02, c.y + d], width: w, length: l),
                .label(.left, [c.x - d, 0.02, c.y], width: w, length: l), .label(.right, [c.x + d, 0.02, c.y], width: w, length: l)]
    }

    // MARK: Xbox

    /// The Xbox (One / Series) controller seen from the front, traced from a photo as a plain outline and made
    /// symmetric; parts where they are on it.
    static let xboxBody: [(CGFloat, CGFloat)] = [
        (0.000, 0.919), (0.000, 0.919), (-0.170, 0.919), (-0.340, 0.920), (-0.510, 0.932), (-0.678, 0.957), (-0.847, 0.974), (-1.015, 0.955),
        (-1.173, 0.894), (-1.311, 0.795), (-1.421, 0.665), (-1.506, 0.518), (-1.577, 0.364), (-1.641, 0.206), (-1.702, 0.047), (-1.758, -0.113),
        (-1.811, -0.275), (-1.862, -0.437), (-1.908, -0.601), (-1.947, -0.766), (-1.980, -0.933), (-2.001, -1.102), (-2.001, -1.272), (-1.969, -1.438),
        (-1.894, -1.590), (-1.772, -1.706), (-1.607, -1.735), (-1.453, -1.668), (-1.327, -1.554), (-1.215, -1.426), (-1.104, -1.298), (-0.983, -1.178),
        (-0.842, -1.084), (-0.679, -1.035), (-0.510, -1.018), (-0.340, -1.014), (-0.170, -1.014), (-0.000, -1.014), (0.000, -1.014), (0.000, -1.014),
        (0.170, -1.014), (0.340, -1.014), (0.510, -1.018), (0.679, -1.035), (0.842, -1.084), (0.983, -1.178), (1.104, -1.298), (1.215, -1.426),
        (1.327, -1.554), (1.453, -1.668), (1.607, -1.735), (1.772, -1.706), (1.894, -1.590), (1.969, -1.438), (2.001, -1.272), (2.001, -1.102),
        (1.980, -0.933), (1.947, -0.766), (1.908, -0.601), (1.862, -0.437), (1.811, -0.275), (1.758, -0.113), (1.702, 0.047), (1.641, 0.206),
        (1.577, 0.364), (1.506, 0.518), (1.421, 0.665), (1.311, 0.795), (1.173, 0.894), (1.015, 0.955), (0.847, 0.974), (0.678, 0.957),
        (0.510, 0.932), (0.340, 0.920), (0.170, 0.919), (-0.000, 0.919)
    ]
    static let xbox = OverlayLayout(
        outline: polygon(xboxBody), middle: 0.4, aspect: 0.74,
        parts: [
            .stick(0, [-1.053, -0.288], radius: 0.21), .stick(1, [0.538, 0.406], radius: 0.21),
            .dpad([-0.59, 0.424], size: 0.6),
            .button(.y, .round(0.13), [1.03, -0.485]), .button(.a, .round(0.13), [1.03, 0.03]),
            .button(.x, .round(0.13), [0.752, -0.224]), .button(.b, .round(0.13), [1.314, -0.224]),
            .button(.guide, .round(0.13), [0, -0.647]),
            .button(.back, .round(0.087), [-0.301, -0.23]), .button(.start, .round(0.087), [0.301, -0.23]),
            .button(.misc, .pill(0.21, 0.127), [0, -0.016]),
            .bumper(.lb, [-1.04, -1.04], width: 0.9), .bumper(.rb, [1.04, -1.04], width: 0.9),
            .trigger(0, [-1.04, -1.22], width: 0.75), .trigger(1, [1.04, -1.22], width: 0.75),
            // Elite back paddles, where a controller has them: out past the handles so they show.
            .grip(.paddle2, [-1.99, 0.06, 0.6], length: 0.5, turn: -0.3), .grip(.paddle1, [1.99, 0.06, 0.6], length: 0.5, turn: 0.3),
            // Labels beside the small parts: bumpers on the upper corners, View and Menu above, Share below.
            .label(.lb, [-1.05, 0.004, -0.8], width: 0.56, length: 0.17), .label(.rb, [1.05, 0.004, -0.8], width: 0.56, length: 0.17),
            .label(.back, [-0.3, 0.004, -0.42], width: 0.28, length: 0.14), .label(.start, [0.3, 0.004, -0.42], width: 0.28, length: 0.14),
            .label(.misc, [0, 0.004, 0.1], width: 0.32, length: 0.15),
            .label(.paddle2, [-1.55, 0.004, 0.8], width: 0.36, length: 0.15), .label(.paddle1, [1.55, 0.004, 0.8], width: 0.36, length: 0.15),
        ])

    // MARK: Switch Pro Controller

    /// Traced from a photo as a plain outline, made symmetric.
    static let switchProBody: [(CGFloat, CGFloat)] = [
        (0.000, 0.950), (0.000, 0.950), (-0.177, 0.949), (-0.353, 0.947), (-0.530, 0.953), (-0.705, 0.968), (-0.882, 0.981), (-1.058, 0.969),
        (-1.229, 0.927), (-1.387, 0.850), (-1.522, 0.737), (-1.628, 0.596), (-1.704, 0.437), (-1.758, 0.269), (-1.799, 0.097), (-1.834, -0.076),
        (-1.866, -0.249), (-1.896, -0.423), (-1.925, -0.598), (-1.954, -0.772), (-1.980, -0.946), (-1.999, -1.122), (-2.004, -1.298), (-1.976, -1.472),
        (-1.897, -1.629), (-1.761, -1.738), (-1.589, -1.757), (-1.432, -1.681), (-1.317, -1.548), (-1.226, -1.397), (-1.138, -1.244), (-1.030, -1.105),
        (-0.880, -1.015), (-0.706, -0.986), (-0.530, -0.982), (-0.353, -0.983), (-0.177, -0.983), (0.000, -0.984), (0.000, -0.984), (-0.000, -0.984),
        (0.177, -0.983), (0.353, -0.983), (0.530, -0.982), (0.706, -0.986), (0.880, -1.015), (1.030, -1.105), (1.138, -1.244), (1.226, -1.397),
        (1.317, -1.548), (1.432, -1.681), (1.589, -1.757), (1.761, -1.738), (1.897, -1.629), (1.976, -1.472), (2.004, -1.298), (1.999, -1.122),
        (1.980, -0.946), (1.954, -0.772), (1.925, -0.598), (1.896, -0.423), (1.866, -0.249), (1.834, -0.076), (1.799, 0.097), (1.758, 0.269),
        (1.704, 0.437), (1.628, 0.596), (1.522, 0.737), (1.387, 0.850), (1.229, 0.927), (1.058, 0.969), (0.882, 0.981), (0.705, 0.968),
        (0.530, 0.953), (0.353, 0.947), (0.177, 0.949), (-0.000, 0.950)
    ]
    static let switchPro = OverlayLayout(
        outline: polygon(switchProBody), depth: 0.4, chamfer: 0.12, middle: 0.4, aspect: 0.74,
        parts: [
            // The D-pad and right stick sit level and mirror each other, as on the controller; the D-pad as wide as a stick.
            .stick(0, [-1.119, -0.178], radius: 0.23), .stick(1, [0.58, 0.39], radius: 0.23),
            .dpad([-0.58, 0.39], size: 0.74),
            // By the letters printed on them, as macOS (and Nokcandu, for a controller it reads itself) reports Nintendo
            // controllers: X top, B bottom, Y left, A right.
            .button(.x, .round(0.145), [1.066, -0.427]), .button(.b, .round(0.145), [1.066, 0.125]),
            .button(.y, .round(0.145), [0.754, -0.153]), .button(.a, .round(0.145), [1.381, -0.153]),
            .button(.back, .pill(0.16, 0.07), [-0.496, -0.456]), .button(.start, .round(0.09), [0.496, -0.456]),
            .button(.misc, .square(0.15), [-0.288, -0.165]), .button(.guide, .round(0.1), [0.272, -0.165]),
            .bumper(.lb, [-1.11, -1.04], width: 0.95), .bumper(.rb, [1.11, -1.04], width: 0.95),
            .trigger(0, [-1.11, -1.22], width: 0.8), .trigger(1, [1.11, -1.22], width: 0.8),
            // Labels beside the small parts: bumpers on the upper corners, − and + above, Capture and Home below.
            .label(.lb, [-1.2, 0.004, -0.84], width: 0.6, length: 0.18), .label(.rb, [1.2, 0.004, -0.84], width: 0.6, length: 0.18),
            .label(.back, [-0.496, 0.004, -0.64], width: 0.3, length: 0.15), .label(.start, [0.496, 0.004, -0.64], width: 0.3, length: 0.15),
            .label(.misc, [-0.288, 0.004, 0.0], width: 0.3, length: 0.15), .label(.guide, [0.272, 0.004, 0.0], width: 0.3, length: 0.15),
        ])

    // MARK: DualShock 4 / DualSense

    /// The DualSense seen from the front, traced from a photo as a plain outline (the bumpers left off, the sides
    /// the photo cut off rounded out), made symmetric.
    static let dualSenseBody: [(CGFloat, CGFloat)] = [
        (0.000, 0.994), (-0.000, 0.994), (-0.174, 0.992), (-0.347, 0.985), (-0.520, 0.974), (-0.693, 0.959), (-0.866, 0.940), (-1.038, 0.917),
        (-1.209, 0.888), (-1.376, 0.842), (-1.528, 0.761), (-1.649, 0.637), (-1.735, 0.487), (-1.797, 0.325), (-1.851, 0.160), (-1.897, -0.008),
        (-1.939, -0.176), (-1.977, -0.345), (-2.013, -0.515), (-2.041, -0.686), (-2.057, -0.859), (-2.052, -1.032), (-2.018, -1.202), (-1.946, -1.360),
        (-1.831, -1.489), (-1.676, -1.562), (-1.506, -1.547), (-1.372, -1.440), (-1.281, -1.293), (-1.206, -1.136), (-1.123, -0.984), (-1.012, -0.852),
        (-0.863, -0.765), (-0.694, -0.730), (-0.521, -0.722), (-0.347, -0.724), (-0.174, -0.726), (-0.000, -0.726), (0.000, -0.726), (0.000, -0.726),
        (0.174, -0.726), (0.347, -0.724), (0.521, -0.722), (0.694, -0.730), (0.863, -0.765), (1.012, -0.852), (1.123, -0.984), (1.206, -1.136),
        (1.281, -1.293), (1.372, -1.440), (1.506, -1.547), (1.676, -1.562), (1.831, -1.489), (1.946, -1.360), (2.018, -1.202), (2.052, -1.032),
        (2.057, -0.859), (2.041, -0.686), (2.013, -0.515), (1.977, -0.345), (1.939, -0.176), (1.897, -0.008), (1.851, 0.160), (1.797, 0.325),
        (1.735, 0.487), (1.649, 0.637), (1.528, 0.761), (1.376, 0.842), (1.209, 0.888), (1.038, 0.917), (0.866, 0.940), (0.693, 0.959),
        (0.520, 0.974), (0.347, 0.985), (0.174, 0.992), (0.000, 0.994)
    ]
    static let dualShock4 = OverlayLayout(
        outline: polygon(dualSenseBody), middle: 0.33, aspect: 0.72,
        parts: [
            .dpad([-1.257, -0.264], size: 0.62),
            .button(.y, .round(0.135), [1.257, -0.565]), .button(.a, .round(0.135), [1.257, 0.037]),
            .button(.x, .round(0.135), [0.956, -0.264]), .button(.b, .round(0.135), [1.553, -0.264]),
            .stick(0, [-0.651, 0.284], radius: 0.2), .stick(1, [0.628, 0.284], radius: 0.2),
            .pad(0, [0, -0.533], .rect(1.5, 0.8), click: .touchpad),
            .button(.back, .pill(0.075, 0.16), [-0.938, -0.704]), .button(.start, .pill(0.075, 0.16), [0.938, -0.704]),
            .button(.guide, .round(0.1), [0, 0.275]), .button(.misc, .pill(0.15, 0.06), [0, 0.513]),
            .bumper(.lb, [-1.257, -1.04], width: 0.8), .bumper(.rb, [1.257, -1.04], width: 0.8),
            .trigger(0, [-1.257, -1.22], width: 0.7), .trigger(1, [1.257, -1.22], width: 0.7),
            // DualSense Edge back buttons: out past the handles so they show.
            .grip(.paddle2, [-2.1, 0.06, 0.7], length: 0.45, turn: -0.2), .grip(.paddle1, [2.1, 0.06, 0.7], length: 0.45, turn: 0.2),
            // Labels beside the small parts: bumpers on the upper corners, Create and Options below, PS above, Mute below.
            .label(.lb, [-1.5, 0.004, -0.86], width: 0.56, length: 0.18), .label(.rb, [1.5, 0.004, -0.86], width: 0.56, length: 0.18),
            .label(.back, [-0.938, 0.004, -0.55], width: 0.2, length: 0.13), .label(.start, [0.938, 0.004, -0.55], width: 0.2, length: 0.13),
            .label(.guide, [0, 0.004, 0.1], width: 0.3, length: 0.14), .label(.misc, [0, 0.004, 0.64], width: 0.3, length: 0.12),
            .label(.paddle2, [-1.62, 0.004, 0.85], width: 0.34, length: 0.15), .label(.paddle1, [1.62, 0.004, 0.85], width: 0.34, length: 0.15),
        ])
}
