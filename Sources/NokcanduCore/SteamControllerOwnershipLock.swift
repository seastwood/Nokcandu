import Foundation
import Darwin

/// One original-controller reader across development/installed Nokcandu copies.
/// The kernel releases ownership after a crash; the separate mode receipt recovers settings.
public final class SteamControllerOwnershipLock {
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    public static func acquire(at url: URL) -> SteamControllerOwnershipLock? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return SteamControllerOwnershipLock(descriptor)
    }
    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
    deinit { release() }
}
