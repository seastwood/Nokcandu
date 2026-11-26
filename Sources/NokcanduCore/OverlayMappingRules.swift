import Foundation

/// Small rules for the overlay's labels that are worth testing on their own.
public enum OverlayMappingRules {
    /// A button that only presses itself (a profile can list it to keep it): nothing to show.
    public static func isItself(_ b: PadProfiles.Binding, _ input: PadProfiles.Input) -> Bool {
        b.tap.isEmpty && b.hold.isEmpty && b.double.isEmpty && b.togetherOutputs.isEmpty && b.turbo == nil && b.togglePress != true
            && (b.press == [.pad(input)] || (input == .lt && b.press == [.trigger(right: false)]) || (input == .rt && b.press == [.trigger(right: true)]))
    }

    /// What a stick does, for its cap: nil when it's a stick as itself.
    public static func stick(_ s: PadProfiles.Stick, side: Int, label: (PadProfiles.Input) -> PadLabel.Text?) -> PadLabel.Text? {
        switch s.mode {
        case .stick: return nil
        case .otherStick: return PadLabel.Text(main: side == 0 ? "R" : "L")
        case .mouse: return PadLabel.Text(main: "Mouse")
        case .flick: return PadLabel.Text(main: "Flick")
        case .scroll: return PadLabel.Text(main: "⇡⇣")
        case .off: return PadLabel.Text(main: "–")
        case .keys:
            let k = s.keys.count == 4 ? s.keys : [13, 1, 0, 2]
            return arranged(k.map(PadLabel.key), middle: "")
        case .directions:
            let d = PadProfiles.Input.stickDirections(side).map { label($0)?.main ?? "·" }
            if s.directionsScroll == true { return arranged(["⇡", "⇣", d[2], d[3]], middle: "") }
            return arranged(d, middle: "")
        }
    }

    /// Four directions drawn around the cap when each is short; otherwise one compass label.
    static func arranged(_ udlr: [String], middle: String) -> PadLabel.Text {
        if udlr.count == 4, udlr.allSatisfy({ $0.count <= 3 }) { return PadLabel.Text(main: middle, around: udlr) }
        return PadLabel.Text(main: compass(udlr))
    }

    /// Up, down, left, right as one short label: single characters read like WASD ("WASD"); longer ones are
    /// joined by spaces, two letters each.
    public static func compass(_ udlr: [String]) -> String {
        guard udlr.count == 4 else { return udlr.joined() }
        let order = [0, 2, 1, 3].map { udlr[$0] }             // up, left, down, right
        return order.allSatisfy { $0.count == 1 } ? order.joined() : order.map { String($0.prefix(2)) }.joined(separator: " ")
    }
}
