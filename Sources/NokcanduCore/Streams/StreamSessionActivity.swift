import Foundation

/// Streaming must stay latency-sensitive even with no controller/profile keeping the process awake.
public final class StreamSessionActivity {
    public static let options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled]
    private var token: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    public init(begin: @escaping () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: StreamSessionActivity.options, reason: "Streaming video, audio and input")
    }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin; self.end = end
    }
    public func start() { if token == nil { token = begin() } }
    public func stop() { if let saved = token { token = nil; end(saved) } }
    deinit { stop() }
}
