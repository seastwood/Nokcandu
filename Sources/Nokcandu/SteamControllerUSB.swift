import Foundation
import AppKit
import IOKit.hid
import NokcanduCore

/// Original wired/receiver Steam Controller source. Takes a verified, reversible volatile
/// mode lease on FF00:1; never resets mappings, pairs devices or updates firmware.
@MainActor
final class SteamControllerUSB: ObservableObject {
    static let shared = SteamControllerUSB()
    @Published private(set) var status = "Not reading Steam Controller"
    @Published private(set) var feedbackStatus = ""
    private var feedback = SteamControllerHaptics()
    private var feedbackFailed = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private final class Channel {
        let device: IOHIDDevice
        let transport: SteamControllerTransport
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        init(_ device: IOHIDDevice, _ transport: SteamControllerTransport) { self.device = device; self.transport = transport }
        deinit { buffer.deallocate() }
    }
    private var channels: [UInt64: Channel] = [:]
    private var active: Channel?
    private let featureQueue = DispatchQueue(label: "Nokcandu.SteamControllerFeatures")
    private var hapticPending = false
    private var session = UUID()
    private var outputGate = SteamControllerOutputGate()
    private var lastScan: Double = 0
    private var lastModeCheck: Double = 0
    private var modeCheckPending = false
    private var captureResets: [Double] = []
    private var stream = SteamControllerStream()
    private var listeners: [UUID: (SteamControllerReport.State?) -> Void] = [:]
    private var timer: Timer?
    private var modeLease: SteamControllerMode.Lease?
    private var radioFingerprint: String?
    private var ownership: SteamControllerOwnershipLock?
    private var terminationObserver: NSObjectProtocol?
    private var recoveryURL: URL { NokPaths.support.appendingPathComponent("steam-controller-mode-lease.json") }
    private var latest: SteamControllerReport.State? { stream.state }
    var connected: Bool { device != nil }
    var controllerName: String? { active.map { "Steam Controller (2015 · \($0.transport.title))" } }

    func listen(_ id: UUID, _ callback: @escaping (SteamControllerReport.State?) -> Void) {
        let existed = listeners[id] != nil
        listeners[id] = callback
        if existed { if manager == nil { start() }; return }
        if manager == nil { start() }
        callback(latest)
    }
    func remove(_ id: UUID) {
        listeners[id] = nil
        if listeners.isEmpty { stop() }
    }
    private func start() {
        try? NokPaths.ensure(NokPaths.support)
        guard let lock = SteamControllerOwnershipLock.acquire(at: NokPaths.support.appendingPathComponent("steam-controller-reader.lock")) else {
            status = "Steam Controller reader unavailable — close any other Nokcandu copy"
            return
        }
        ownership = lock; captureResets = []; lastModeCheck = 0
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, [0x1102, 0x1142].map { product in
            [kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:product,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1]
        } as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _,_,_,d in
            MainActor.assumeIsolated { SteamControllerUSB.shared.add(d) }
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _,_,_,d in
            MainActor.assumeIsolated { SteamControllerUSB.shared.removeDevice(d) }
        }, nil)
        manager = m
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SteamControllerUSB.shared.stop() }
        }
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(m,0)
        status = r == kIOReturnSuccess ? "Connect the original Steam Controller by USB or wake it with its receiver connected" : "Steam Controller interface could not be opened"
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { SteamControllerUSB.shared.expire() } }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    private func add(_ d: IOHIDDevice) {
        func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(d,key as CFString) as? NSNumber)?.intValue ?? 0 }
        let interface = (IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d),kIOServicePlane,"bInterfaceNumber" as CFString,kCFAllocatorDefault,IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber)?.intValue ?? -1
        guard let transport = SteamControllerTransport.identify(vendor:number(kIOHIDVendorIDKey), product:number(kIOHIDProductIDKey), page:number(kIOHIDPrimaryUsagePageKey), usage:number(kIOHIDPrimaryUsageKey), interface:interface) else { return }
        let id = registryID(d)
        guard channels[id] == nil else { return }
        let channel = Channel(d,transport); channels[id] = channel
        IOHIDDeviceRegisterInputReportCallback(d,channel.buffer,64,{ ctx,result,_,_,id,bytes,count in
            guard result == kIOReturnSuccess, id == 0, count == 64, let ctx else { return }
            let channel = Unmanaged<Channel>.fromOpaque(ctx).takeUnretainedValue()
            let report = Array(UnsafeBufferPointer(start:bytes,count:count))
            MainActor.assumeIsolated { SteamControllerUSB.shared.report(report,from:channel) }
        },Unmanaged.passUnretained(channel).toOpaque())
        chooseController()
    }
    private func chooseController() {
        guard device == nil else { return }
        // Cable first at initial selection; never switch away from a live controller.
        let candidates = channels.values.sorted { a,b in
            if a.transport != b.transport { return a.transport == .cable }
            return registryID(a.device) < registryID(b.device)
        }
        featureQueue.sync {} // finish feedback before starting another feature transaction
        for channel in candidates {
            guard acquireMode(channel.device,transport:channel.transport) else { continue }
            active = channel; device = channel.device; stream.reset(); session = UUID(); outputGate = SteamControllerOutputGate()
            feedback.reset(); feedbackFailed = false; feedbackStatus = ""
            status = "\(channel.transport.title) connected; waiting for full controller input"
            for f in Array(listeners.values) { f(nil) }
            return
        }
        status = channels.values.contains(where: { $0.transport == .receiver })
            ? "Wireless receiver detected; waiting for a controller with verified desktop capture"
            : "Steam Controller takeover could not be verified — input paused to avoid duplicate desktop actions"
    }
    private func removeDevice(_ d: IOHIDDevice) {
        let id = registryID(d)
        guard let channel = channels.removeValue(forKey:id) else { return }
        IOHIDDeviceRegisterInputReportCallback(d,channel.buffer,64,nil,nil)
        if active === channel {
            // Removed hardware cannot be restored. Wireless receiver identity is not
            // remote-controller identity: recovery is keyed by the queried remote digest.
            outputGate.cancel(); radioFingerprint = nil; modeLease = nil; device = nil; active = nil; session = UUID(); reset()
            status = "Steam Controller disconnected"
        }
        chooseController()
    }
    private func report(_ bytes: [UInt8], from channel: Channel) {
        guard channels[registryID(channel.device)] === channel else { return }
        if channel.transport == .receiver, let event = SteamControllerTransport.event(bytes) {
            if event == .disconnected, active === channel {
                outputGate.cancel(); radioFingerprint = nil; modeLease = nil; device = nil; active = nil; session = UUID(); feedback.reset(); reset()
                status = "Wireless controller disconnected — outputs released; receiver still connected"
            } else if event == .connected, device == nil { chooseController() }
            return
        }
        guard active === channel, modeLease != nil,
              let state = stream.accept(bytes,at:ProcessInfo.processInfo.systemUptime) else { return }
        let next = "Receiving Steam Controller input (\(channel.transport.title) · desktop controls captured)"
        if status != next { status = next }
        for f in Array(listeners.values) { f(state) }
    }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        verifyCapture(at:now)
        if device == nil, !channels.isEmpty, now - lastScan >= 2 {
            lastScan = now; chooseController()
        }
        guard stream.expire(at:ProcessInfo.processInfo.systemUptime) else { return }
        reset(); feedback.reset()
        if active?.transport == .receiver {
            // The USB slot survives wake, and a radio disconnect notification can
            // be missed. A stale lease must not prevent reacquiring that controller.
            // Keep its identity-keyed original-mode receipt for the next verified scan.
            outputGate.cancel(); modeLease = nil; radioFingerprint = nil
            device = nil; active = nil; session = UUID(); lastScan = 0
            status = "Wireless input paused — outputs released; waiting for verified capture"
        } else {
            // A cable pulled and plugged back in can come back as the same or a new connection without a
            // removal notice. Let go of the silent one so the controller is taken over again; its recovery
            // record restores its own mode first if it is still the same connection.
            outputGate.cancel(); modeLease = nil
            device = nil; active = nil; session = UUID(); lastScan = 0
            status = "USB input paused — checking the controller again"
        }
    }
    private func verifyCapture(at now: Double) {
        guard let transport = active?.transport, let device, let lease=modeLease,
              !modeCheckPending,now-lastModeCheck>=1 else{return}
        modeCheckPending=true;lastModeCheck=now
        let token=session
        featureQueue.async {
            let current=Self.readSettings(device,transport:transport)
            Task { @MainActor in
                self.modeCheckPending=false
                guard self.session==token,self.modeLease==lease else{return}
                if transport == .cable, current == nil { return }       // one missed reply over the cable is not a change
                guard current==lease.applied else {
                    // A reset to our measured baseline can happen on wake even if
                    // vendor reports continue. Do not map alongside desktop mode.
                    self.outputGate.cancel();self.modeLease=nil;self.radioFingerprint=nil
                    self.reset();self.feedback.reset();self.session=UUID()
                    self.captureResets=self.captureResets.filter{now-$0<10}
                    // Over the cable, a controller that went back to its own mode (plugged back in, woken)
                    // is taken over again; another app's different mode is still left alone over the radio.
                    if (current==lease.original || transport == .cable),self.captureResets.count<3 {
                        self.captureResets.append(now)
                        self.device=nil;self.active=nil;self.lastScan=0
                        self.status = transport == .cable ? "Steam Controller back in its own mode — taking it over again" : "Wireless desktop mode returned — checking capture again"
                    } else {
                        // Unknown/competing modes are preserved, not repeatedly fought.
                        self.status="Wireless capture changed — outputs released. Turn profiles off and leave this test, then reopen to retry."
                    }
                    return
                }
            }
        }
    }
    private func reset() {
        stream.reset()
        for f in Array(listeners.values) { f(nil) }
    }
    private func stop() {
        outputGate.cancel()
        feedback.reset()
        timer?.invalidate(); timer = nil
        for channel in channels.values { IOHIDDeviceRegisterInputReportCallback(channel.device,channel.buffer,64,nil,nil) }
        // Serialize restoration after any already queued transient feedback.
        featureQueue.sync {}
        restoreMode()
        ownership?.release(); ownership = nil
        if let observer = terminationObserver { NotificationCenter.default.removeObserver(observer) }; terminationObserver = nil
        device = nil; active = nil; session = UUID(); stream.reset()
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m,0)
        }
        channels.removeAll()
        manager = nil; status = "Not reading Steam Controller"
    }

    @discardableResult
    func movementFeedback(side: Int, dx: Int, dy: Int, strength: Double, rate: Double = 40, spacingMS: Double = 1, followsMovement: Bool = false) -> Bool {
        guard let bytes = feedback.movement(side: side, dx: dx, dy: dy, strength: strength, rate: rate, spacingMS: spacingMS, followsMovement: followsMovement, at: ProcessInfo.processInfo.systemUptime) else { return false }
        return sendFeedback(bytes)
    }
    /// One haptic tick, as for a scroll step. Skipped (not queued) while a receiver send is still pending.
    @discardableResult
    func tick(side: Int, strength: Double) -> Bool {
        guard let bytes = SteamControllerHaptics.pulse(side: side, strength: strength) else { return false }
        return sendFeedback(bytes)
    }
    @discardableResult
    func touchFeedback(side: Int, down: Bool, strength: Double) -> Bool {
        guard let bytes = feedback.touch(side: side, down: down, strength: strength, at: ProcessInfo.processInfo.systemUptime) else { return false }
        return sendFeedback(bytes)
    }
    private func sendFeedback(_ report: [UInt8]) -> Bool {
        guard !feedbackFailed, modeLease != nil, ownership != nil, let device else { return false }
        var bytes = report
        if active?.transport == .receiver {
            guard !hapticPending else { return false }
            hapticPending = true
            let token = session
            let report = bytes
            let gate = outputGate
            featureQueue.async {
                let sent = Self.send(report,to:device,transport:.receiver,gate:gate)
                Task { @MainActor in
                    self.hapticPending = false
                    guard self.session == token else { return }
                    if !sent { self.feedbackFailed = true; self.feedbackStatus = "Pad haptics unavailable on this connection" }
                }
            }
            return true
        }
        let result = IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&bytes,bytes.count)
        if result != kIOReturnSuccess {
            feedbackFailed = true; feedbackStatus = "Pad haptics unavailable on this connection"
            return false
        }
        return true
    }
    /// Rumbles both pads. Returns false when no Steam Controller is being read, so callers can say so.
    @discardableResult
    func rumble(strong: Bool) -> Bool { rumble(strength: strong ? 1 : 0.6, seconds: strong ? 0.4 : 0.15) }
    @discardableResult
    func rumble(strength: Double, seconds: Double) -> Bool {
        guard !feedbackFailed, modeLease != nil, ownership != nil, let device,
              let left = SteamControllerHaptics.rumble(side: 0, strength: strength, seconds: seconds),
              let right = SteamControllerHaptics.rumble(side: 1, strength: strength, seconds: seconds) else { return false }
        if active?.transport == .receiver {
            guard !hapticPending else { return false }
            hapticPending = true
            let token = session, gate = outputGate
            featureQueue.async {
                let sent = Self.send(left, to: device, transport: .receiver, gate: gate) && Self.send(right, to: device, transport: .receiver, gate: gate)
                Task { @MainActor in
                    self.hapticPending = false
                    guard self.session == token else { return }
                    if !sent { self.feedbackStatus = "Rumble didn't reach the controller over the receiver" }
                }
            }
            return true
        }
        var a = left, b = right
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &a, a.count) == kIOReturnSuccess
            && IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &b, b.count) == kIOReturnSuccess
    }
    func testFeedback(side: Int, strength: Double, rate: Double = 40, spacingMS: Double = 1) {
        if movementFeedback(side: side, dx: 1, dy: 0, strength: strength, rate: rate, spacingMS: spacingMS) { feedbackStatus = "Short haptic burst sent — move the pad to feel the repeat rate" }
        else if modeLease != nil && device != nil && !feedbackFailed { feedbackStatus = "Haptics are already pulsing — stop the pad before testing" }
        else { feedbackStatus = "Haptic pulse unavailable — connect the controller by USB or receiver and open its profile test" }
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var value: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &value)
        return value
    }
    nonisolated private static func send(_ data: [UInt8], to device: IOHIDDevice, transport: SteamControllerTransport, gate: SteamControllerOutputGate? = nil) -> Bool {
        transport.transfer(attempt: {
            guard gate?.isActive != false else { return false }
            var bytes = data
            return IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&bytes,bytes.count) == kIOReturnSuccess
        },pause: { Thread.sleep(forTimeInterval:0.0005) })
    }
    private func settings(_ device: IOHIDDevice, transport: SteamControllerTransport) -> SteamControllerMode.Settings? {
        Self.readSettings(device,transport:transport)
    }
    nonisolated private static func readSettings(_ device: IOHIDDevice, transport: SteamControllerTransport) -> SteamControllerMode.Settings? {
        guard Self.send(SteamControllerMode.query,to:device,transport:transport) else { return nil }
        for _ in 0..<(transport == .receiver ? 20 : 10) {
            if transport == .receiver { Thread.sleep(forTimeInterval:0.003) }
            var bytes = [UInt8](repeating:0,count:64), count = 64
            let got = transport.transfer(attempt: {
                count = 64
                return IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,0,&bytes,&count) == kIOReturnSuccess
            },pause: { Thread.sleep(forTimeInterval:0.0005) })
            if got, count >= 0, count <= bytes.count,
               let value = SteamControllerMode.decode(Array(bytes.prefix(count))) { return value }
            if transport == .cable { Thread.sleep(forTimeInterval:0.001) }
        }
        return nil
    }
    private func write(_ values: SteamControllerMode.Settings, to device: IOHIDDevice, transport: SteamControllerTransport) -> Bool {
        guard let bytes = SteamControllerMode.write(values) else { return false }
        return Self.send(bytes,to:device,transport:transport)
    }
    private func remoteIdentity(_ device: IOHIDDevice) -> String? {
        guard Self.send(SteamControllerIdentity.query,to:device,transport:.receiver) else { return nil }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval:0.003) // an empty successful reply can still mean pending radio response
            var bytes=[UInt8](repeating:0,count:64),count=64
            let got=SteamControllerTransport.receiver.transfer(attempt:{
                count=64
                return IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,0,&bytes,&count)==kIOReturnSuccess
            },pause:{Thread.sleep(forTimeInterval:0.0005)})
            if got,count>=0,count<=64,let identity=SteamControllerIdentity.fingerprint(Array(bytes.prefix(count))) { return identity }
        }
        return nil
    }
    private func radioRecoveryURL(_ identity: String) -> URL {
        NokPaths.support.appendingPathComponent("steam-wireless-mode-"+identity+".json")
    }
    private func acquireMode(_ device: IOHIDDevice, transport: SteamControllerTransport) -> Bool {
        let id = registryID(device)
        guard var original = settings(device,transport:transport) else { return false }
        var identity: String?
        if transport == .receiver {
            guard let currentIdentity=remoteIdentity(device) else { return false }
            identity=currentIdentity
            let url=radioRecoveryURL(currentIdentity)
            if FileManager.default.fileExists(atPath:url.path) {
                guard let data=try? Data(contentsOf:url),let prior=try? JSONDecoder().decode(SteamControllerIdentity.Recovery.self,from:data),
                      prior.fingerprint==currentIdentity,prior.applied==SteamControllerMode.captured(prior.original) else{return false}
                if let recovered=prior.recoveredOriginal(identity:currentIdentity,current:original) { original=recovered }
                // A changed mode belongs to another owner and becomes the new baseline.
            }
        }
        if transport == .cable, FileManager.default.fileExists(atPath: recoveryURL.path) {
            guard let data = try? Data(contentsOf: recoveryURL),
                  let prior = try? JSONDecoder().decode(SteamControllerMode.Lease.self, from: data),
                  prior.applied == SteamControllerMode.captured(prior.original) else { return false }
            if prior.canRestore(device: id, current: original) {
                guard write(prior.original, to: device,transport:transport), settings(device,transport:transport) == prior.original else { return false }
                _ = Self.send(SteamControllerMode.defaultDigitalMappings,to:device,transport:transport)
                original = prior.original
            }
            // A different connection/settings owner is never restored from this journal.
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        guard let lease = SteamControllerMode.Lease(device: id, original: original),
              let data = try? JSONEncoder().encode(lease) else { return false }
        do {
            try NokPaths.ensure(NokPaths.support)
            if let identity,let recovery=SteamControllerIdentity.Recovery(fingerprint:identity,original:original) {
                try JSONEncoder().encode(recovery).write(to:radioRecoveryURL(identity),options:.atomic)
            } else { try data.write(to:recoveryURL,options:.atomic) }
        } catch { return false }
        guard write(lease.applied, to: device,transport:transport), settings(device,transport:transport) == lease.applied else {
            if let current = settings(device,transport:transport), current == lease.applied { _ = write(original, to: device,transport:transport) }
            return false
        }
        // Built-in trigger clicks and button keys are not covered by the settings above.
        if !Self.send(SteamControllerMode.clearDigitalMappings,to:device,transport:transport) {
            NSLog("Nokcandu: the Steam Controller kept its built-in button actions (clear request not accepted)")
        }
        modeLease = lease; radioFingerprint=identity
        return true
    }
    private func restoreMode() {
        guard let device, let lease = modeLease, let transport = active?.transport else { return }
        modeLease = nil
        let identity=radioFingerprint; radioFingerprint=nil
        if transport == .receiver {
            guard let identity,remoteIdentity(device)==identity else{return}
        }
        guard let current = settings(device,transport:transport) else { return } // keep recovery for a later verified retry
        if lease.canRestore(device: registryID(device), current: current) {
            guard write(lease.original, to: device,transport:transport), settings(device,transport:transport) == lease.original else { return }
            _ = Self.send(SteamControllerMode.defaultDigitalMappings,to:device,transport:transport)
        }
        // Another app's changed mode is preserved, never overwritten.
        if let identity { try? FileManager.default.removeItem(at:radioRecoveryURL(identity)) }
        else { try? FileManager.default.removeItem(at: recoveryURL) }
    }
}
