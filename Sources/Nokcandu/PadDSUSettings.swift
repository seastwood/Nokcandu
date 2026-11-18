import SwiftUI
import GameController
import NokcanduCore

/// A single dispatcher owns each macOS motion callback. Mapping and DSU receive the same event without
/// replacing one another's handlers, including while streams reconfigure their controller players.
@MainActor enum PadMotionHandlers {
    private static var installed:Set<ObjectIdentifier> = []
    private static var consumers:[ObjectIdentifier:(GCMotion)->Void] = [:]
    private static var dsuActivated:Set<ObjectIdentifier> = []
    static func set(_ controller:GCController,handler:((GCMotion)->Void)?) {
        guard let motion = controller.motion else { return }
        let id = ObjectIdentifier(controller)
        let live = Set(GCController.controllers().map(ObjectIdentifier.init)).union([id])
        installed.formIntersection(live); consumers = consumers.filter { live.contains($0.key) }; dsuActivated.formIntersection(live)
        consumers[id] = handler
        if handler == nil && !PadDSUBridge.shared.isServing {
            motion.valueChangedHandler = nil; installed.remove(id)
            if dsuActivated.remove(id) != nil { motion.sensorsActive = false }
            return
        }
        installed.insert(id)
        motion.valueChangedHandler = { motion in
            MainActor.assumeIsolated {
                PadDSUBridge.shared.publish(source:"gc:\(id)",motion:motion)
                consumers[id]?(motion)
            }
        }
    }
    static func configureDSU(_ on:Bool) {
        let controllers = GCController.controllers(), live = Set(controllers.map(ObjectIdentifier.init))
        installed.formIntersection(live); consumers = consumers.filter { live.contains($0.key) }; dsuActivated.formIntersection(live)
        for controller in controllers {
            guard let motion = controller.motion else { continue }
            let id = ObjectIdentifier(controller)
            if on {
                if motion.sensorsRequireManualActivation && !motion.sensorsActive { motion.sensorsActive = true; dsuActivated.insert(id) }
                if !installed.contains(id) { set(controller,handler:nil) }
            } else if consumers[id] == nil {
                motion.valueChangedHandler = nil; installed.remove(id)
                if dsuActivated.remove(id) != nil { motion.sensorsActive = false }
            }
        }
    }
}

@MainActor final class PadDSUBridge:ObservableObject {
    static let shared = PadDSUBridge()
    @Published var enabled = UserDefaults.standard.bool(forKey:"dsuMotionEnabled") {
        didSet { UserDefaults.standard.set(enabled,forKey:"dsuMotionEnabled"); configure() }
    }
    @Published var port:Int = (UserDefaults.standard.object(forKey:"dsuMotionPort") as? Int) ?? 26760 {
        didSet { UserDefaults.standard.set(port,forKey:"dsuMotionPort"); configure() }
    }
    @Published private(set) var status = "Off"
    private var server:DSUServer?
    var isServing:Bool { server != nil }
    private let steamID = UUID()
    private var observer:NSObjectProtocol?
    private var generation = UUID()
    private var retiring:Set<UUID> = []
    private var pendingStart:UUID?
    func configure() {
        stop()
        guard enabled,AppFeatures.current.contains(.profiles) else { return }
        guard (1024...65535).contains(port) else { status = "Choose a port between 1024 and 65535."; return }
        let token = UUID(); generation = token; pendingStart = token; status = "Starting…"
        startWhenReady()
    }
    private func startWhenReady() {
        guard retiring.isEmpty,let token = pendingStart,generation == token else { return }
        pendingStart = nil
        let next = DSUServer(port:UInt16(port)); server = next
        next.onStatus = { [weak self] line in Task { @MainActor in
            guard let self,self.generation == token else { return }
            if line.hasPrefix("DSU:") { self.stop() }
            self.status = line
        } }
        status = "Starting…"; next.start()
        PadMotionHandlers.configureDSU(true)
        observer = NotificationCenter.default.addObserver(forName:.GCControllerDidConnect,object:nil,queue:.main) { _ in
            MainActor.assumeIsolated { PadMotionHandlers.configureDSU(true) }
        }
        MappedGamepads.shared.start()
        SteamControllerUSB.shared.listen(steamID) { [weak self] state in
            if let state { self?.publish(source:"steam-direct",gyro:state.gyro,acceleration:state.acceleration) }
        }
    }
    func stop() {
        generation = UUID(); pendingStart = nil
        if let old = server {
            let id = UUID(); retiring.insert(id)
            old.stop { [weak self] in Task { @MainActor in
                self?.retiring.remove(id); self?.startWhenReady()
            } }
        }
        server = nil
        SteamControllerUSB.shared.remove(steamID)
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        PadMotionHandlers.configureDSU(false)
        status = enabled ? "Paused while Remapping is hidden" : "Off"
    }
    func publish(source:String,gyro:[Float],acceleration:[Float]) { server?.publish(source:source,gyro:gyro,acceleration:acceleration) }
    func publish(source:String,motion:GCMotion) {
        guard server != nil else { return }
        let r = motion.rotationRate,a = motion.acceleration
        publish(source:source,gyro:[Float(r.x),Float(r.y),Float(r.z)],acceleration:[Float(a.x),Float(a.y),Float(a.z)])
    }
}

struct PadDSUSettings:View {
    @ObservedObject private var bridge = PadDSUBridge.shared
    var body:some View {
        Section("Emulator motion (DSU)") {
            Toggle("Send raw controller motion to local emulators",isOn:$bridge.enabled)
            TextField("UDP port",value:$bridge.port,format:.number.grouping(.never)).disabled(!bridge.enabled)
            Text("In a compatible emulator, choose DSU/CemuHook and 127.0.0.1 with this port. Up to four motion sources; buttons use the emulator's normal controller setup. Available only on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text(bridge.status).font(.caption).foregroundStyle(.secondary)
            if bridge.enabled { Button("Retry DSU Server") { bridge.configure() } }
        }
    }
}
