import Foundation
import NokcanduCore

@MainActor
final class PadProfileEdits {
    static let shared = PadProfileEdits()
    private lazy var queue = PadEditQueue<PadProfiles.Profile>(schedule: { delay, action in
        let job = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
        return { job.cancel() }
    }, didChange: { DesktopPad.shared.evaluate(force: true) })
    static func scope(profileID: String, contents: URL?) -> String {
        contents.map { "own:" + $0.resolvingSymlinksInPath().standardizedFileURL.path } ?? "profile:" + profileID
    }
    func submit(_ profile: PadProfiles.Profile, contents: URL?, persist: @escaping (PadProfiles.Profile) -> Void) {
        queue.submit(profile, scope: Self.scope(profileID: profile.id, contents: contents), persist: persist)
    }
    func profiles(_ saved: [PadProfiles.Profile]) -> [PadProfiles.Profile] {
        saved.map { queue.value(scope: Self.scope(profileID: $0.id, contents: nil)) ?? $0 }
    }
    func own(contents: URL) -> PadProfiles.Profile? { queue.value(scope: Self.scope(profileID: "", contents: contents)) }
    func flush(_ key: String) { queue.flush(key) }
    func flushAll() { queue.flushAll() }
}
