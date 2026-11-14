// SPDX-License-Identifier: GPL-3.0-only
// Plays rumble from Windows games on controllers SDL can't rumble (see NokcanduCore/ControllerRumble.swift):
// the original Steam Controller through its trackpad haptics, others through macOS's controller haptics.
import CoreHaptics
import Darwin
import Foundation
import GameController
import IOKit.hid
import NokcanduCore

@MainActor
final class ControllerRumbleRouter {
    static let shared = ControllerRumbleRouter()
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    private var states: [String: (request: ControllerRumble.Request, state: ControllerRumble.State)] = [:]
    private var timer: Timer?
    private var steam: IOHIDManager?
    private var steamDevices: [IOHIDDevice] = []
    private let steamQueue = DispatchQueue(label: "nokcandu.rumble.steam", qos: .userInteractive)
    private var steamBusy = false
    /// Receiver slots that took the last pulse: a receiver has one per controller, and empty ones only time out.
    private var steamWorking: Set<IOHIDDevice> = []
    private(set) var played = 0

    func start() {
        guard socket < 0 else { return }
        try? NokPaths.ensure(NokPaths.support)
        let path = ControllerRumble.socketFile.path
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            guard path.utf8.count < buf.count else { return false }
            buf.copyBytes(from: path.utf8); buf[path.utf8.count] = 0; return true
        }
        let bound = ok && withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard bound else { close(fd); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        socket = fd
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        s.resume(); source = s
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = recv(socket, &buf, buf.count, 0)
            guard n > 0 else { break }
            guard let r = ControllerRumble.Request.parse(String(decoding: buf[0..<n], as: UTF8.self)) else { continue }
            let key = String(format: "%04x:%04x", r.vendor, r.product)
            var st = states[key]?.state ?? ControllerRumble.State()
            st.apply(r, now: CACurrentMediaTime())
            states[key] = (r, st)
        }
        tick()
        if timer == nil, states.values.contains(where: { $0.state.strength(at: CACurrentMediaTime()) > 0 }) {
            let t = Timer(timeInterval: 0.08, repeats: true) { _ in MainActor.assumeIsolated { ControllerRumbleRouter.shared.tick() } }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
    }

    /// Renews each controller's buzz in short overlapping pulses, so a stop (or the game going away) ends it quickly.
    private func tick() {
        let now = CACurrentMediaTime()
        var any = false
        for (_, entry) in states {
            let asked = entry.state.strength(at: now)
            guard asked > 0 else { continue }
            any = true
            // The profile's Game rumble setting scales it (0: off).
            let level = asked * DesktopPad.shared.gameRumble
            guard level > 0.01 else { continue }
            play(entry.request, strength: level, seconds: 0.12)
        }
        if !any { timer?.invalidate(); timer = nil; states = states.filter { $0.value.state.until > now - 1 } }
    }

    private func play(_ r: ControllerRumble.Request, strength: Double, seconds: Double) {
        played += 1
        if ControllerRumble.isOriginalSteamController(vendor: r.vendor, product: r.product) {
            // When Nokcandu already reads the controller itself, it sends haptics through that connection.
            if SteamControllerUSB.shared.rumble(strength: strength, seconds: seconds) { return }
            steamRumble(strength: strength, seconds: seconds)
            return
        }
        let haptic = GCController.controllers().filter { $0.haptics != nil }
        let named = haptic.filter { ($0.vendorName ?? "").caseInsensitiveCompare(r.name) == .orderedSame }
        let targets = !named.isEmpty ? named : (haptic.count == 1 ? haptic : [])
        PadFeedback.shared.rumble(targets, strength: strength, seconds: seconds)
    }

    /// The Steam Controller's vendor interface, opened without taking it over: haptic pulses are feature reports and
    /// change nothing else about the controller.
    private func steamRumble(strength: Double, seconds: Double) {
        if steam == nil {
            let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
            IOHIDManagerSetDeviceMatchingMultiple(m, [0x1102, 0x1142].map { product in
                [kIOHIDVendorIDKey: 0x28de, kIOHIDProductIDKey: product, kIOHIDDeviceUsagePageKey: 0xff00, kIOHIDDeviceUsageKey: 1]
            } as CFArray)
            IOHIDManagerOpen(m, 0)
            steam = m
        }
        guard let m = steam, !steamBusy,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let left = SteamControllerHaptics.rumble(side: 0, strength: strength, seconds: seconds),
              let right = SteamControllerHaptics.rumble(side: 1, strength: strength, seconds: seconds) else { return }
        let devices: [(IOHIDDevice, SteamControllerTransport)] = set.compactMap { d in
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
            let interface = (IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d), kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber)?.intValue ?? -1
            return SteamControllerTransport.identify(vendor: number(kIOHIDVendorIDKey), product: number(kIOHIDProductIDKey),
                                                     page: number(kIOHIDPrimaryUsagePageKey), usage: number(kIOHIDPrimaryUsageKey), interface: interface).map { (d, $0) }
        }
        guard !devices.isEmpty else { return }
        let known = devices.filter { steamWorking.contains($0.0) }
        steamBusy = true
        nonisolated(unsafe) let work = known.isEmpty ? devices : known
        steamQueue.async {
            var ok: [IOHIDDevice] = []
            for (d, transport) in work {
                var sent = true
                for report in [left, right] {
                    sent = transport.transfer(attempt: {
                        var bytes = report
                        return IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0, &bytes, bytes.count) == kIOReturnSuccess
                    }, pause: { Thread.sleep(forTimeInterval: 0.0005) }) && sent
                }
                if sent { ok.append(d) }
            }
            nonisolated(unsafe) let good = ok
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let r = ControllerRumbleRouter.shared
                r.steamBusy = false
                r.steamWorking = Set(good)
            } }
        }
    }
}
