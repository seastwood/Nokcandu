import Foundation

/// Policy for controller-generated relative mouse events. Does not seize physical devices.
public struct PadCapturePolicy {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case disabled, manual, automatic
    }
    public private(set) var targetPID: Int32?
    private var foregroundPID: Int32?
    private var previousMode: Mode = .disabled
    private var manualPID: Int32?
    private var suspendedPID: Int32?
    public init() {}

    /// A foreground identity change always discards manual activation and emergency overrides.
    public mutating func update(pid: Int32?, mode: Mode, permitted: Bool, windowAvailable: Bool) {
        if foregroundPID != pid { manualPID = nil; suspendedPID = nil }
        foregroundPID = pid
        if previousMode != mode { manualPID = nil }
        previousMode = mode
        guard permitted, windowAvailable, let pid, pid > 0, suspendedPID != pid else {
            targetPID = nil; manualPID = nil; return
        }
        if mode == .disabled { manualPID = nil }
        targetPID = mode == .automatic || (mode == .manual && manualPID == pid) ? pid : nil
    }
    public mutating func toggleManual(pid: Int32) {
        guard pid > 0, foregroundPID == pid else { return }
        if targetPID == pid { release() }
        else { manualPID = pid; suspendedPID = nil }
    }
    /// Remains released until foreground changes or the user explicitly reactivates.
    public mutating func release() {
        suspendedPID = foregroundPID; manualPID = nil; targetPID = nil
    }
    public mutating func reset() {
        targetPID = nil; foregroundPID = nil; manualPID = nil; suspendedPID = nil; previousMode = .disabled
    }
}
