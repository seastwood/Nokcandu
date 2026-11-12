import CoreGraphics

/// A release always follows its down-event's process and position for captured input.
public struct PadMouseButtons {
    public struct Output { public let event: CGEvent; public let target: Int32 }
    private struct Hold { var target: Int32; var point: CGPoint }
    private var holds: [Int: Hold] = [:]
    public var held: Set<Int> { Set(holds.keys) }
    public init() {}
    public mutating func event(button: Int, down: Bool, target: Int32, point: CGPoint, flags: CGEventFlags) -> Output? {
        guard (0...4).contains(button) else { return nil }
        if down && holds[button] != nil { return nil }
        if !down && holds[button] == nil { return nil }
        let hold = down ? Hold(target: target, point: point) : holds[button]!
        let location = hold.target > 0 ? hold.point : point
        let type: CGEventType = button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        guard let event = CGEvent(mouseEventSource: PadEventSource.source(), mouseType: type,
            mouseCursorPosition: location, mouseButton: CGMouseButton(rawValue: UInt32(button))!) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        PadEventSource.mark(event)
        if down { holds[button] = hold } else { holds[button] = nil }
        return Output(event: event, target: hold.target)
    }
}
