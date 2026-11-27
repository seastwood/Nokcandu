// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What a profile from someone else would do that's worth knowing before adding it: a shared profile is a set of
/// key presses, and a macro can type anything (a command into Terminal, a message) or press ⌘ shortcuts.
public enum PadProfileImportReview {
    static let command: Set<Int> = [55, 54]     // left and right ⌘
    public static func notes(_ profiles: [PadProfiles.Profile]) -> [String] {
        var typed: [String] = [], commandUses = 0, macros = 0, sequences = 0
        func outputs(of b: PadProfiles.Binding) -> [PadProfiles.Output] {
            b.press + b.tap + b.hold + b.double + b.togetherOutputs + (b.release ?? []) + (b.longHold ?? []) + (b.cycle ?? []).flatMap { $0 }
        }
        func uses(_ o: [PadProfiles.Output]) {
            if o.contains(where: { if case .key(let k) = $0.heldOutput { return command.contains(k) }; return false }) { commandUses += 1 }
        }
        for p in profiles {
            for layer in p.layers { for b in layer.bindings.values { uses(outputs(of: b)) } }
            for m in p.macros ?? [] {
                macros += 1
                for s in m.steps {
                    if s.kind == .text, let t = s.text, !t.isEmpty { typed.append(t) }
                    uses((s.output.map { [$0] } ?? []) + (s.outputs ?? []))
                }
            }
            for s in p.sequences ?? [] { sequences += 1; uses(s.outputs) }
            for menu in p.menus ?? [] { for slice in menu.slices { uses(slice.outputs) } }
        }
        var out: [String] = []
        for t in typed.prefix(5) {
            let one = t.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "⏎")
            out.append("Types: “\(one.count > 80 ? String(one.prefix(80)) + "…" : one)”")
        }
        if typed.count > 5 { out.append("And types \(typed.count - 5) more texts.") }
        if commandUses > 0 { out.append("Presses ⌘ shortcuts (\(commandUses) place\(commandUses == 1 ? "" : "s")), which can quit apps, open Spotlight or run commands in the app in front.") }
        if macros > 0 && typed.isEmpty { out.append("Has \(macros) macro\(macros == 1 ? "" : "s").") }
        if sequences > 0 { out.append("Has \(sequences) button sequence\(sequences == 1 ? "" : "s").") }
        return out
    }
}
