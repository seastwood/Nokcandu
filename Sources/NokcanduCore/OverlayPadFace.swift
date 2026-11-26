import Foundation

/// What a trackpad's face shows on the controller overlay: its regions (directions, zones, the edge ring), each
/// with what it does and whether it's held or toggled on, plus a word for what the pad does as a whole (mouse,
/// stick…) and its click. Pure geometry and text; the overlay draws it.
public struct OverlayPadFace: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Angles in degrees, counter-clockwise from the right (y up); radii as fractions of the pad's radius.
        case sector(from: Double, to: Double, inner: Double, outer: Double)
        case disc(radius: Double)
    }
    public struct Region: Equatable, Sendable {
        public var shape: Shape
        public var text: PadLabel.Text?
        public var active: Bool
        public var toggled: Bool
        /// Where its label goes: angle (degrees) and radius.
        public var at: (angle: Double, radius: Double)
        public static func == (a: Region, b: Region) -> Bool {
            a.shape == b.shape && a.text == b.text && a.active == b.active && a.toggled == b.toggled && a.at == b.at
        }
    }
    public var regions: [Region] = []
    /// What the pad does as a whole ("Mouse"), shown in its middle when nothing else is there.
    public var centre: String?
    public var click: PadLabel.Text?
    public var clickActive = false
    public init() {}

    /// A Steam Controller trackpad. `label` gives what an input does (nil: nothing set).
    public static func steamPad(side: Int, settings s: PadSteamTrackpadSettings, label: (PadProfiles.Input) -> PadLabel.Text?,
                                held: Set<PadProfiles.Input>, toggled: Set<PadProfiles.Input>, clickInput: PadProfiles.Input, clicked: Bool) -> OverlayPadFace {
        var f = OverlayPadFace()
        let turn = min(45, max(-45, s.rotation ?? 0))            // a zone's angles on the pad are its layout's, less the pad angle
        let edge = PadSteamPadZones.edgeSize(s), outer = edge > 0 ? 1 - edge : 1
        func region(_ shape: Shape, _ input: PadProfiles.Input, at: (Double, Double), showEmpty: Bool = false) {
            let t = label(input)
            guard t != nil || showEmpty else { return }
            f.regions.append(Region(shape: shape, text: t ?? PadLabel.Text(main: "·"), active: held.contains(input), toggled: toggled.contains(input), at: at))
        }
        func sector(_ centre: Double, half: Double, inner: Double) -> Shape { .sector(from: centre - half - turn, to: centre + half - turn, inner: inner, outer: outer) }
        if s.mode == .directions {
            let d = PadProfiles.Input.padDirections(side), dead = PadSteamPadZones.deadzone(s), mid = (dead + outer) / 2
            for (i, c) in [90.0, 270, 180, 0].enumerated() { region(sector(c, half: 45, inner: dead), d[i], at: (c - turn, mid), showEmpty: true) }
        } else if let layout = s.zoneLayout, layout != .off {
            // Zones: each shows its tap, and its click when that's set too.
            let parts: [(Shape, (Double, Double))]
            switch layout {
            case .off: parts = []
            case .leftRight: parts = [(sector(180, half: 90, inner: 0), (180, 0.5)), (sector(0, half: 90, inner: 0), (0, 0.5))]
            case .topBottom: parts = [(sector(90, half: 90, inner: 0), (90, 0.5)), (sector(270, half: 90, inner: 0), (270, 0.5))]
            case .quadrants: parts = [(sector(135, half: 45, inner: 0), (135, 0.55)), (sector(45, half: 45, inner: 0), (45, 0.55)),
                                      (sector(225, half: 45, inner: 0), (225, 0.55)), (sector(315, half: 45, inner: 0), (315, 0.55))]
            case .cross: parts = [(.disc(radius: 0.35), (0, 0)), (sector(90, half: 45, inner: 0.35), (90, 0.66)), (sector(270, half: 45, inner: 0.35), (270, 0.66)),
                                  (sector(180, half: 45, inner: 0.35), (180, 0.66)), (sector(0, half: 45, inner: 0.35), (0, 0.66))]
            }
            for (n, p) in parts.enumerated() {
                let tap = PadProfiles.Input.padZoneTap(side, n), click = PadProfiles.Input.padZoneClick(side, n)
                var t = label(tap), c = label(click)
                if t == nil { t = c; c = nil }
                guard var text = t else { continue }
                if let c { text.second = "⏎" + c.main }
                f.regions.append(Region(shape: p.0, text: text, active: held.contains(tap) || held.contains(click),
                                        toggled: toggled.contains(tap) || toggled.contains(click), at: (p.1.0 - (n == 0 && layout == .cross ? 0 : turn), p.1.1)))
            }
        }
        if edge > 0 {
            let e = PadProfiles.Input.padEdge(side)
            if let t = label(e) {
                f.regions.append(Region(shape: .sector(from: 0, to: 360, inner: outer, outer: 1), text: t, active: held.contains(e), toggled: toggled.contains(e), at: (90, 1 - edge / 2)))
            }
        }
        switch s.mode {
        case .mouse: f.centre = "Mouse"
        case .trackball: f.centre = "Ball"
        case .stick: f.centre = side == 0 ? "L Stick" : "R Stick"
        case .velocityStick: f.centre = "Aim"
        case .dial: f.centre = "⟳ Scroll"
        case .absolute: f.centre = "Region"
        case .gestures: f.centre = "Draw"
        case .directions, .existing: break
        }
        if f.regions.isEmpty, f.centre == nil, let tap = label(.padTap(side)) { f.centre = tap.main }
        f.click = label(clickInput)
        f.clickActive = clicked
        return f
    }
}
