/// Window-local recorder decisions, separate from event monitoring and profile persistence.
public struct PadOutputRecorder {
    public enum Input {
        case key(Int), modifier(Int, down: Bool), mouseButton(Int), wheel(Double)
    }
    public enum Result: Equatable {
        case waiting, cancelled, outputs([PadProfiles.Output])
    }
    private var modifiers = Set<Int>()
    public init() {}
    public mutating func reset() { modifiers = [] }
    public mutating func receive(_ input: Input) -> Result {
        let result: Result
        switch input {
        case .key(53): result = .cancelled // Escape remains available through the explicit output menu.
        case .key(let code):
            guard (0..<128).contains(code) else { return .waiting }
            result = .outputs(modifiers.sorted().map { .key($0) } + [.key(code)])
        case .modifier(let code, let down):
            guard (0..<128).contains(code) else { return .waiting }
            if down { modifiers.insert(code); return .waiting }
            guard modifiers.contains(code) else { return .waiting }
            result = .outputs([.key(code)])
        case .mouseButton(let button):
            let buttons: [PadProfiles.MouseButton] = [.left, .right, .middle, .back, .forward]
            guard buttons.indices.contains(button) else { return .waiting }
            result = .outputs([.mouse(buttons[button])])
        case .wheel(let delta):
            guard delta.isFinite, abs(delta) > 0.5 else { return .waiting }
            result = .outputs([.wheel(up: delta > 0)])
        }
        reset(); return result
    }
}
