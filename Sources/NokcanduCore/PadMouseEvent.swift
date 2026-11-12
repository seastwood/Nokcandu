import CoreGraphics

/// Builds desktop controller movement without posting it. Prefer left, then right,
/// then the lowest extra button when several buttons are held, matching Wine's
/// existing left-before-right policy. Event type and button must agree.
public enum PadMouseEvent {
    public static func movement(at point: CGPoint, dx: Int, dy: Int,
                                heldButtons: Set<Int>, flags: CGEventFlags) -> CGEvent? {
        let held = heldButtons.filter { (0...4).contains($0) }.min()
        let button = CGMouseButton(rawValue: UInt32(held ?? 0))!
        let type: CGEventType
        switch held {
        case 0: type = .leftMouseDragged
        case 1: type = .rightMouseDragged
        case .some: type = .otherMouseDragged
        case nil: type = .mouseMoved
        }
        guard let event = CGEvent(mouseEventSource: PadEventSource.source(), mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.flags = flags
        PadEventSource.mark(event)
        return event
    }
}
