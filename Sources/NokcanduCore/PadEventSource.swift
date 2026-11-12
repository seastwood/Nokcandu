import CoreGraphics

/// Explicit marker survives conversion to NSEvent, unlike assumptions about a nil event source.
public enum PadEventSource {
    public static let marker: Int64 = 0x4e4f4b504144
    public static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = marker
        return source
    }
    public static func mark(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: marker) }
    public static func isOwn(_ event: CGEvent, processID: Int32) -> Bool {
        isOwn(userData: event.getIntegerValueField(.eventSourceUserData),
              sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID), processID: processID)
    }
    public static func isOwn(userData: Int64, sourcePID: Int64, processID: Int32) -> Bool {
        userData == marker || sourcePID == Int64(processID)
    }
}
