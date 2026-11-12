import Foundation

/// State observed by one test window, never global keyboard state or typed text.
public struct PadInputObservation {
    public enum Input: Equatable {
        case key(Int, down: Bool, repeated: Bool)
        case button(Int, down: Bool)
        case modifiers(UInt64)
        case interrupted
    }
    public struct Entry: Equatable {
        public let seconds: Double
        public let input: Input
        public let mapped: Bool
    }
    public private(set) var keys = Set<Int>()
    public private(set) var buttons = Set<Int>()
    public private(set) var modifierFlags: UInt64 = 0
    public private(set) var interrupted = false
    public private(set) var history: [Entry] = []
    private var start: Double
    public init(start: Double) { self.start = start.isFinite ? start : 0 }
    public mutating func reset(at time: Double) { self = Self(start: time) }
    public mutating func receive(_ input: Input, mapped: Bool, at time: Double) {
        switch input {
        case .key(let code, let down, _):
            guard (0..<128).contains(code) else { return }
            if down { keys.insert(code) } else { keys.remove(code) }
        case .button(let button, let down):
            guard (0..<32).contains(button) else { return }
            if down { buttons.insert(button) } else { buttons.remove(button) }
        case .modifiers(let flags): modifierFlags = flags
        case .interrupted:
            // A release outside this window may never arrive. Clearing observation
            // is not evidence that the output was released in the target/OS.
            keys = []; buttons = []; modifierFlags = 0; interrupted = true
        }
        let seconds = time.isFinite ? max(history.last?.seconds ?? 0, time - start) : history.last?.seconds ?? 0
        history.append(Entry(seconds: max(0, seconds), input: input, mapped: mapped))
        if history.count > 32 { history.removeFirst(history.count - 32) }
    }
}
