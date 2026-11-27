// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Quick setups for players who can't hold buttons down or reach both sides of the controller.
public enum PadAccessibility {
    /// Every hold becomes a toggle: press once to hold, again to let go. Mapped buttons' keys, mouse buttons,
    /// controller buttons and layer holds toggle instead; a button left as itself toggles itself. Layer switches,
    /// gyro, macros and menus are left as they are.
    public static func holdsAsToggles(_ layer: PadProfiles.Layer, base: Bool) -> PadProfiles.Layer {
        var l = layer
        for (key, b) in layer.bindings {
            var c = b
            c.press = b.press.map(toggled)
            l.bindings[key] = c
        }
        if base {
            for i in PadProfiles.Input.padButtons where l[i] == nil && i != .guide { l[i] = .as(.padToggle(i)) }
        }
        return l
    }
    static func toggled(_ o: PadProfiles.Output) -> PadProfiles.Output {
        if case .layerHold(let n) = o { return .layerToggle(n) }
        return o.toggledOutput ?? o
    }
    /// Whether a layer already has every hold as a toggle (for the menu's wording).
    public static func togglesHolds(_ layer: PadProfiles.Layer) -> Bool {
        let outputs = layer.bindings.values.flatMap(\.press)
        return !outputs.isEmpty && !outputs.contains { toggled($0) != $0 }
    }

    /// One hand: holding the bumper on the hand's side gives the other side's controls on this side. Left hand: hold
    /// L for the right side (the D-pad is A, B, X and Y by position, the left stick is the right stick, ZL/LT is
    /// RT, L3 is R3, View/− is Menu/+). Right hand: hold R for the left side, mirrored.
    public static func oneHanded(_ p: PadProfiles.Profile, left: Bool) -> PadProfiles.Profile {
        var p = p
        let name = left ? "Right side" : "Left side"
        if !p.layers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { p.layers.append(PadProfiles.Layer(name: name)) }
        let i = p.layers.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }!
        var layer = PadProfiles.Layer(id: p.layers[i].id, name: name)
        if left {
            layer[.up] = .as(.pad(.y)); layer[.right] = .as(.pad(.b)); layer[.down] = .as(.pad(.a)); layer[.left] = .as(.pad(.x))
            layer[.lt] = .as(.trigger(right: true)); layer[.ls] = .as(.pad(.rs)); layer[.back] = .as(.pad(.start))
            var s = PadProfiles.Stick(); s.mode = .otherStick; layer.leftStick = s
            p.layers[0][.lb] = .as(.layerHold(name))
        } else {
            layer[.y] = .as(.pad(.up)); layer[.b] = .as(.pad(.right)); layer[.a] = .as(.pad(.down)); layer[.x] = .as(.pad(.left))
            layer[.rt] = .as(.trigger(right: false)); layer[.rs] = .as(.pad(.ls)); layer[.start] = .as(.pad(.back))
            var s = PadProfiles.Stick(); s.mode = .otherStick; layer.rightStick = s
            p.layers[0][.rb] = .as(.layerHold(name))
        }
        layer.color = p.layers[i].color
        p.layers[i] = layer
        return p
    }
}
