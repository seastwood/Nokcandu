import SwiftUI
#if !CONTROLLER_DIAGRAM_PREVIEW
import NokcanduCore
#endif

/// Presentation only: selection and mappings come from the existing editor, with no input/profile changes.
struct Steam2026ControllerDiagram: View {
    typealias G = Steam2026PictureGeometry
    struct ButtonState {
        var binding: String?
        var mapped = false, pressed = false, changed = false
        var color: Color?
    }
    struct StickState {
        var position = CGPoint.zero
        var mapping: String?, click: String?
        var pressed = false, changed = false
    }
    var selected: G.Part?
    var buttons: [G.Control: ButtonState] = [:]
    var sticks: [StickState] = []
    var padPositions: [CGPoint] = []
    var padClicks: [String?] = []
    var padPressed: [Bool] = []
    var padChanged: [Bool] = []
    var tint: Color = .accentColor
    var padFace: (Int, CGFloat) -> AnyView = { _, _ in AnyView(EmptyView()) }
    var select: (G.Part) -> Void

    var body: some View {
        GeometryReader { geo in
            let g = G(width: geo.size.width)
            ZStack {
                Steam2026Shape()
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                    .overlay(Steam2026Shape().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .frame(width: g.body.width, height: g.body.height).position(x: g.body.midX, y: g.body.midY)
                    .accessibilityHidden(true)
                dpadWell(g).fill(Color(nsColor: .controlBackgroundColor))
                    .allowsHitTesting(false).accessibilityHidden(true)
                ForEach(0..<2, id: \.self) { side in
                    let r = g.stickRect(side), c = g.stickCaptionRect(side)
                    Path { p in
                        p.move(to: CGPoint(x: side == 0 ? r.minX + 5 : r.maxX - 5, y: r.midY + r.height * 0.3))
                        p.addLine(to: CGPoint(x: side == 0 ? c.maxX : c.minX, y: c.midY))
                    }.stroke(Color.secondary.opacity(0.4), lineWidth: 0.7).allowsHitTesting(false).accessibilityHidden(true)
                    stick(side, g)
                    trackpad(side, g)
                }
                ForEach(G.Control.allCases, id: \.self) { control in
                    button(control, g)
                    if let text = clean(buttons[control]?.binding) { caption(control, text, g) }
                }
                Button { select(.gyro) } label: {
                    Label("Gyro", systemImage: "gyroscope")
                        .font(.system(size: max(7, 11 * g.scale))).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: g.gyro.width, height: g.gyro.height)
                        .background(Capsule().fill(selected == .gyro ? tint.opacity(0.35) : Color.primary.opacity(0.08)))
                        .overlay(Capsule().stroke(selected == .gyro ? tint : Color.secondary.opacity(0.3), lineWidth: selected == .gyro ? 2 : 0.5))
                }.buttonStyle(.plain).position(x: g.gyro.midX, y: g.gyro.midY).accessibilityLabel("Gyro settings")
                Button { select(.rumble) } label: {
                    Label("Rumble", systemImage: "waveform.path")
                        .font(.system(size: max(7, 11 * g.scale))).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: g.rumble.width, height: g.rumble.height)
                        .background(Capsule().fill(selected == .rumble ? tint.opacity(0.35) : Color.primary.opacity(0.08)))
                        .overlay(Capsule().stroke(selected == .rumble ? tint : Color.secondary.opacity(0.3), lineWidth: selected == .rumble ? 2 : 0.5))
                }.buttonStyle(.plain).position(x: g.rumble.midX, y: g.rumble.midY).accessibilityLabel("Rumble settings")
            }.frame(width: geo.size.width, height: geo.size.height)
        }
    }
    private func clean(_ text: String?) -> String? { text.flatMap { $0.isEmpty || $0 == "—" ? nil : $0 } }
    private func dpadWell(_ g: G) -> Path {
        let up = g.controlRect(.up), down = g.controlRect(.down)
        let left = g.controlRect(.left), right = g.controlRect(.right)
        let corner = CGSize(width: 5 * g.scale, height: 5 * g.scale)
        return Path { p in
            p.addRoundedRect(in: CGRect(x: up.minX, y: up.minY, width: up.width, height: down.maxY - up.minY), cornerSize: corner)
            p.addRoundedRect(in: CGRect(x: left.minX, y: left.minY, width: right.maxX - left.minX, height: left.height), cornerSize: corner)
        }
    }
    private func button(_ control: G.Control, _ g: G) -> some View {
        let state = buttons[control] ?? ButtonState(), r = g.controlRect(control)
        let color = state.color ?? tint
        let shape = [.up, .down, .left, .right].contains(control)
            ? AnyShape(RoundedRectangle(cornerRadius: 5 * g.scale)) : AnyShape(Capsule())
        return Button { select(.button(control)) } label: {
            Text(control.title).font(.system(size: max(7, 11 * g.scale), weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(state.pressed ? Color.white : Color.primary)
                .frame(width: r.width, height: r.height)
                .background(shape.fill(state.pressed ? color : state.mapped ? color.opacity(0.35) : Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(selected == .button(control) ? color : Color.secondary.opacity(0.35), lineWidth: selected == .button(control) ? 2 : 0.5))
                .overlay(alignment: .topTrailing) { if state.changed { changeDot(g.scale) } }
        }.buttonStyle(.plain).position(x: r.midX, y: r.midY)
            .accessibilityLabel(control.title + (clean(state.binding).map { ": " + $0 } ?? ""))
    }
    private func caption(_ control: G.Control, _ text: String, _ g: G) -> some View {
        let r = g.captionRect(control)
        let align: TextAlignment = [.left, .x, .ltfull].contains(control) ? .trailing : [.right, .b, .rtfull].contains(control) ? .leading : .center
        return Button { select(.button(control)) } label: {
            Text(text).font(.system(size: max(6, 10 * g.scale), weight: .medium))
                .multilineTextAlignment(align).lineLimit(r.height < 18 * g.scale ? 1 : 2).truncationMode(.tail)
                .foregroundStyle(buttons[control]?.color ?? tint)
                .frame(width: r.width, height: r.height, alignment: align == .leading ? .leading : align == .trailing ? .trailing : .center)
                .clipped().contentShape(Rectangle())
        }.buttonStyle(.plain).position(x: r.midX, y: r.midY).help(text).accessibilityHidden(true)
    }
    @ViewBuilder private func stick(_ side: Int, _ g: G) -> some View {
        let s = sticks.indices.contains(side) ? sticks[side] : StickState()
        let r = g.stickRect(side), c = g.stickCaptionRect(side)
        Button { select(.stick(side)) } label: {
            Circle().fill(s.pressed ? tint.opacity(0.5) : s.mapping != nil ? tint.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().stroke(selected == .stick(side) ? tint : Color.secondary.opacity(0.4), lineWidth: selected == .stick(side) ? 2 : 0.5))
                .overlay(Circle().fill(Color.primary.opacity(0.55)).frame(width: 12 * g.scale, height: 12 * g.scale)
                    .offset(x: s.position.x * 20 * g.scale, y: -s.position.y * 20 * g.scale))
                .overlay(alignment: .topTrailing) { if s.changed { changeDot(g.scale) } }
                .frame(width: r.width, height: r.height)
        }.buttonStyle(.plain).position(x: r.midX, y: r.midY).accessibilityLabel(side == 0 ? "Left stick settings" : "Right stick settings")
        let text = [clean(s.mapping), clean(s.click).map { "click: " + $0 }].compactMap { $0 }.joined(separator: " · ")
        Button { select(.stick(side)) } label: {
            VStack(alignment: side == 0 ? .trailing : .leading, spacing: 1) {
                Text(side == 0 ? "Left stick" : "Right stick").font(.system(size: max(6, 9 * g.scale))).foregroundStyle(.secondary)
                if !text.isEmpty { Text(text).font(.system(size: max(6, 10 * g.scale), weight: .medium)).foregroundStyle(tint).lineLimit(2).truncationMode(.tail) }
            }.multilineTextAlignment(side == 0 ? .trailing : .leading)
                .frame(width: c.width, height: c.height, alignment: side == 0 ? .trailing : .leading).clipped().contentShape(Rectangle())
        }.buttonStyle(.plain).position(x: c.midX, y: c.midY).help(text).accessibilityHidden(true)
    }
    @ViewBuilder private func trackpad(_ side: Int, _ g: G) -> some View {
        let r = g.padRect(side), c = g.padCaptionRect(side), p = padPositions.indices.contains(side) ? padPositions[side] : .zero
        let pressed = padPressed.indices.contains(side) && padPressed[side]
        let changed = padChanged.indices.contains(side) && padChanged[side]
        Button { select(.trackpad(side)) } label: {
            RoundedRectangle(cornerRadius: 12 * g.scale).fill(tint.opacity(pressed ? 0.45 : 0.16))
                .overlay(padFace(side, r.width).clipShape(RoundedRectangle(cornerRadius: 12 * g.scale)))
                .overlay(RoundedRectangle(cornerRadius: 12 * g.scale).stroke(selected == .trackpad(side) ? tint : Color.secondary.opacity(0.45), lineWidth: selected == .trackpad(side) ? 2 : 1))
                .overlay(Circle().fill(Color.primary.opacity(0.55)).frame(width: 10 * g.scale, height: 10 * g.scale)
                    .offset(x: p.x * r.width * 0.42, y: -p.y * r.height * 0.42))
                .overlay(alignment: .topTrailing) { if changed { changeDot(g.scale) } }
                .frame(width: r.width, height: r.height).rotationEffect(.degrees(G.padAngle(side)))
        }.buttonStyle(.plain).position(x: r.midX, y: r.midY).accessibilityLabel(side == 0 ? "Left trackpad settings" : "Right trackpad settings")
        let click = padClicks.indices.contains(side) ? clean(padClicks[side]) : nil
        Button { select(.trackpad(side)) } label: {
            VStack(spacing: 1) {
                Text(side == 0 ? "Left trackpad" : "Right trackpad").font(.system(size: max(6, 10 * g.scale), weight: .semibold))
                if let click { Text("click: " + click).font(.system(size: max(6, 9 * g.scale))).foregroundStyle(tint).lineLimit(2).truncationMode(.tail) }
            }.frame(width: c.width, height: c.height, alignment: .top).clipped().contentShape(Rectangle())
        }.buttonStyle(.plain).position(x: c.midX, y: c.midY).help(click ?? "Trackpad settings").accessibilityHidden(true)
    }
    private func changeDot(_ scale: CGFloat) -> some View {
        Circle().fill(tint).frame(width: max(3, 5 * scale), height: max(3, 5 * scale)).accessibilityHidden(true)
    }
}

/// Outline proportions from the supplied front-on product reference.
struct Steam2026Shape: Shape {
    func path(in r: CGRect) -> Path {
        Path(Steam2026PictureGeometry.shellPath(in: r))
    }
}
