import Foundation
import Network

/// Local-only UDP server. Packet handling and checksumming never execute on the UI/input thread.
public final class DSUServer: @unchecked Sendable {
    private let queue = DispatchQueue(label:"nokcandu.dsu",qos:.userInitiated)
    private let port:UInt16
    private let serverID = UInt32.random(in:1...UInt32.max)
    private var listener:NWListener?
    private var clients:[ObjectIdentifier:NWConnection] = [:]
    private var subscriptions:[ObjectIdentifier:[DSUMotionState.Subscription]] = [:]
    private var activity:[ObjectIdentifier:TimeInterval] = [:]
    private var state = DSUMotionState()
    private var sweep:DispatchSourceTimer?
    public var onStatus: (@Sendable (String) -> Void)?
    public init(port:UInt16 = 26760) { self.port = port }
    public func start() { queue.async { self.startOnQueue() } }
    private func startOnQueue() {
        guard listener == nil, port > 0 else { return }
        do {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!)
            let listener = try NWListener(using:parameters); self.listener = listener
            listener.stateUpdateHandler = { [weak self,weak listener] status in
                guard let self,self.listener === listener else { return }
                switch status {
                case .ready: self.onStatus?("Listening on 127.0.0.1:\(self.port)")
                case .waiting(let error): self.onStatus?("DSU waiting: \(error.localizedDescription)")
                case .failed(let error): self.onStatus?("DSU: \(error.localizedDescription)"); self.stopOnQueue()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener.start(queue:queue)
            let timer = DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+1,repeating:1)
            timer.setEventHandler { [weak self] in self?.expire() }; timer.resume(); sweep = timer
        } catch { onStatus?("DSU: \(error.localizedDescription)") }
    }
    public func stop(completion:(@Sendable () -> Void)? = nil) { queue.async { self.stopOnQueue(completion:completion) } }
    private func stopOnQueue(completion:(@Sendable () -> Void)? = nil) {
        let old = listener; listener = nil; sweep?.cancel(); sweep = nil
        for c in clients.values { c.cancel() }
        clients = [:];subscriptions = [:];activity = [:];state = DSUMotionState()
        if let old,let completion {
            // A replacement must wait for the old socket to release its port, including rapid off/on.
            old.stateUpdateHandler = { if case .cancelled = $0 { completion() } }
            old.cancel()
        } else { old?.cancel(); completion?() }
    }
    private func accept(_ connection:NWConnection) {
        expire()
        guard clients.count < 16 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        clients[id] = connection; activity[id] = ProcessInfo.processInfo.systemUptime
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(id) }
            else if case .cancelled = state { self?.remove(id) }
        }
        connection.start(queue:queue); receive(connection)
    }
    private func remove(_ id:ObjectIdentifier) {
        clients.removeValue(forKey:id)?.cancel(); subscriptions[id] = nil; activity[id] = nil
    }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        for id in Array(clients.keys) where now-(activity[id] ?? 0) >= 5 { remove(id) }
        for id in subscriptions.keys { subscriptions[id]?.removeAll { $0.until <= now } }
    }
    private func receive(_ connection:NWConnection) {
        connection.receiveMessage { [weak self,weak connection] data,_,_,error in
            guard let self,let connection,self.clients[ObjectIdentifier(connection)] === connection else { return }
            if let data { self.handle(data,from:connection) }
            if error == nil { self.receive(connection) } else { self.remove(ObjectIdentifier(connection)) }
        }
    }
    private func handle(_ data:Data,from connection:NWConnection) {
        guard let request = DSUProtocol.request(data) else { return }
        let now = ProcessInfo.processInfo.systemUptime,id = ObjectIdentifier(connection)
        activity[id] = now
        switch request {
        case .version:
            connection.send(content:DSUProtocol.frame(type:0x100000,body:[0xe9,3,0,0],id:serverID),completion:.idempotent)
        case .ports(let ports):
            for slot in ports { connection.send(content:DSUProtocol.info(slot:Int(slot),connected:state.connected(Int(slot),now:now),mac:state.sources[Int(slot)]?.mac ?? [],id:serverID),completion:.idempotent) }
        case .subscribe(let flags,let slot,let mac):
            var list = (subscriptions[id] ?? []).filter { $0.until > now && !($0.flags == flags && $0.slot == slot && $0.mac == mac) }
            if list.count < 8 { list.append(.init(flags:flags,slot:slot,mac:mac,until:now+5)) }
            subscriptions[id] = list
        }
    }
    public func publish(source:String,gyro:[Float],acceleration:[Float],now:TimeInterval = ProcessInfo.processInfo.systemUptime) {
        queue.async {
            guard self.listener != nil, let slot = self.state.publish(id:source,gyro:gyro,acceleration:acceleration,now:now),
                  let value = self.state.sources[slot], let packet = DSUProtocol.motion(slot:slot,mac:value.mac,counter:value.counter,micros:value.micros,gyro:gyro,acceleration:acceleration,id:self.serverID) else { return }
            for (id,c) in self.clients where self.subscriptions[id]?.contains(where:{ $0.includes(slot:slot,source:value,now:now) }) == true {
                c.send(content:packet,completion:.idempotent)
            }
        }
    }
}
