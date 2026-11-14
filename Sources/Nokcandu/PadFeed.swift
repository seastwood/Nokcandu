// SPDX-License-Identifier: GPL-3.0-only
// Sends a profile's controller output to the Windows game in front, for profiles that read the controller themselves
// (the original Steam Controller read directly). Wine's controller driver (Resources/rawmouse/padmap.m, "Fed by
// Nokcandu") turns it into the controller the game sees and drops that controller's raw input.
import Darwin
import QuartzCore
import Foundation

@MainActor
final class PadFeed {
    static let shared = PadFeed()
    private var fd: Int32 = -1
    private var environment: URL?
    private var socketPath: String?
    private var checked = 0.0
    private var buttons: [Int: Bool] = [:], axes: [Int: Int] = [:]

    /// The environment of the Windows game in front (nil: none, or the profile doesn't read the controller itself).
    func target(_ env: URL?) {
        guard env != environment else { return }
        release()
        environment = env; socketPath = nil; checked = 0
    }

    /// False when there's no game to feed (the caller then sends the output elsewhere).
    func button(_ b: Int, _ down: Bool) -> Bool {
        guard send(kind: 1, code: b, value: down ? 1 : 0) else { return false }
        buttons[b] = down; return true
    }
    func axis(_ a: Int, _ v: Int) -> Bool {
        guard send(kind: 2, code: a, value: v) else { return false }
        axes[a] = v; return true
    }

    /// Lets go of everything held, so a game losing focus isn't left with a button down.
    func release() {
        for (b, down) in buttons where down { _ = send(kind: 1, code: b, value: 0) }
        for (a, v) in axes where v != 0 { _ = send(kind: 2, code: a, value: 0) }
        buttons = [:]; axes = [:]
    }

    private func path() -> String? {
        guard let env = environment else { return nil }
        let now = CACurrentMediaTime()
        if socketPath == nil || now - checked > 1 {
            checked = now
            socketPath = (try? String(contentsOf: env.appendingPathComponent("SharedSupport/nokcandu/pad-feed"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return socketPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func send(kind: UInt8, code: Int, value: Int) -> Bool {
        guard let p = path() else { return false }
        if fd < 0 { fd = socket(AF_UNIX, SOCK_DGRAM, 0) }
        guard fd >= 0 else { return false }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            guard p.utf8.count < buf.count else { return false }
            buf.copyBytes(from: p.utf8); buf[p.utf8.count] = 0; return true
        }
        guard fits else { return false }
        var msg: (UInt8, UInt8, Int16) = (kind, UInt8(truncatingIfNeeded: code), Int16(clamping: value))
        let sent = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, &msg, 4, MSG_DONTWAIT, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if sent != 4 { socketPath = nil; return false }
        return true
    }
}
