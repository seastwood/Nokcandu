import Foundation

/// DSU/CemuHook v1001 framing, per the protocol reference and Dolphin's packed protocol structures.
/// Motion only: button/stick fields are neutral; existing gamepad routing remains independent.
public enum DSUProtocol {
    public static let version: UInt16 = 1001
    public enum Request: Equatable {
        case version
        case ports([UInt8])
        case subscribe(flags:UInt8,slot:UInt8,mac:[UInt8])
    }
    public static func crc32(_ bytes:[UInt8]) -> UInt32 {
        var crc:UInt32 = 0xffffffff
        for b in bytes { crc ^= UInt32(b); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xedb88320 : 0) } }
        return ~crc
    }
    public static func read(_ bytes:[UInt8],at:Int,count:Int) -> UInt64 {
        guard at >= 0, count >= 0, count <= 8, at <= bytes.count, count <= bytes.count-at else { return 0 }
        return (0..<count).reduce(0) { $0 | (UInt64(bytes[at+$1]) << ($1*8)) }
    }
    static func put(_ value:UInt64,into bytes:inout [UInt8],at:Int,count:Int) {
        for i in 0..<count { bytes[at+i] = UInt8(truncatingIfNeeded:value >> (8*i)) }
    }
    public static func frame(type:UInt32,body:[UInt8],id:UInt32,client:Bool = false) -> Data {
        var bytes = Array((client ? "DSUC":"DSUS").utf8) + Array(repeating:UInt8(0),count:16+body.count)
        put(UInt64(version),into:&bytes,at:4,count:2); put(UInt64(body.count+4),into:&bytes,at:6,count:2)
        put(UInt64(id),into:&bytes,at:12,count:4); put(UInt64(type),into:&bytes,at:16,count:4)
        bytes.replaceSubrange(20..<bytes.count,with:body)
        put(UInt64(crc32(bytes)),into:&bytes,at:8,count:4)
        return Data(bytes)
    }
    public static func request(_ data:Data) -> Request? {
        let all = Array(data)
        guard all.count >= 20, all.count <= 100, Array(all.prefix(4)) == Array("DSUC".utf8),
              read(all,at:4,count:2) == UInt64(version) else { return nil }
        let length = Int(read(all,at:6,count:2))+16
        guard length >= 20, length <= all.count else { return nil }
        var bytes = Array(all.prefix(length)); let crc = read(bytes,at:8,count:4)
        put(0,into:&bytes,at:8,count:4); guard UInt64(crc32(bytes)) == crc else { return nil }
        switch read(bytes,at:16,count:4) {
        case 0x100000: return length == 20 ? .version : nil
        case 0x100001:
            guard length >= 24 else { return nil }
            let count = Int(read(bytes,at:20,count:4))
            guard (1...4).contains(count), length >= 24+count else { return nil }
            let ports = Array(bytes[24..<(24+count)]); guard ports.allSatisfy({ $0 < 4 }) else { return nil }
            return .ports(ports)
        case 0x100002:
            guard length == 28, bytes[20] & ~3 == 0, bytes[20] & 1 == 0 || bytes[21] < 4 else { return nil }
            return .subscribe(flags:bytes[20],slot:bytes[21],mac:Array(bytes[22..<28]))
        default: return nil
        }
    }
    public static func info(slot:Int,connected:Bool,mac:[UInt8],id:UInt32) -> Data {
        frame(type:0x100001,body:prefix(slot:slot,connected:connected,mac:mac)+[0],id:id)
    }
    private static func prefix(slot:Int,connected:Bool,mac:[UInt8]) -> [UInt8] {
        [UInt8(clamping:slot),connected ? 2:0,connected ? 2:0,0] + Array((mac+Array(repeating:0,count:6)).prefix(6)) + [0]
    }
    public static func motion(slot:Int,mac:[UInt8],counter:UInt32,micros:UInt64,gyro:[Float],acceleration:[Float],id:UInt32) -> Data? {
        guard gyro.count == 3, acceleration.count == 3, (gyro+acceleration).allSatisfy(\.isFinite) else { return nil }
        var body = prefix(slot:slot,connected:true,mac:mac) + Array(repeating:UInt8(0),count:69)
        body[11] = 1; put(UInt64(counter),into:&body,at:12,count:4)
        for i in 20..<24 { body[i] = 128 }
        put(micros,into:&body,at:48,count:8)
        for i in 0..<3 {
            put(UInt64(acceleration[i].bitPattern),into:&body,at:56+4*i,count:4)
            let degrees = gyro[i] * Float(180 / Double.pi)
            guard degrees.isFinite else { return nil }
            put(UInt64(degrees.bitPattern),into:&body,at:68+4*i,count:4)
        }
        return frame(type:0x100002,body:body,id:id)
    }
}

/// Bounded, deterministic source slots and expiring subscriptions; transport owns it on one serial queue.
public struct DSUMotionState {
    public struct Source {
        public let id:String
        public let mac:[UInt8]
        public var gyro:[Float], acceleration:[Float]
        public var seen:TimeInterval
        public var micros:UInt64
        public var counter:UInt32
    }
    public struct Subscription {
        public var flags:UInt8,slot:UInt8,mac:[UInt8],until:TimeInterval
        public func includes(slot index:Int,source:Source,now:TimeInterval) -> Bool {
            now < until && (flags == 0 || flags & 1 != 0 && Int(slot) == index || flags & 2 != 0 && mac == source.mac)
        }
    }
    public private(set) var sources:[Int:Source] = [:]
    public init() {}
    @discardableResult public mutating func publish(id:String,gyro:[Float],acceleration:[Float],now:TimeInterval) -> Int? {
        guard now.isFinite, now >= 0, now < Double(UInt64.max)/1_000_000,
              gyro.count == 3,acceleration.count == 3,(gyro+acceleration).allSatisfy(\.isFinite) else { return nil }
        let existing = sources.first { $0.value.id == id }?.key
        guard let slot = existing ?? (0..<4).first(where:{ sources[$0] == nil || now-sources[$0]!.seen > 2 }) else { return nil }
        var hash:UInt32 = 2166136261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let mac:[UInt8] = [2,0x4e] + (0..<4).map { UInt8(truncatingIfNeeded:hash >> ($0*8)) }
        let old = existing.flatMap { sources[$0] }
        guard old == nil || now >= old!.seen else { return nil }
        sources[slot] = Source(id:id,mac:mac,gyro:gyro,acceleration:acceleration,seen:now,
                              micros:UInt64(now*1_000_000),counter:(old?.counter ?? 0) &+ 1)
        return slot
    }
    public func connected(_ slot:Int,now:TimeInterval) -> Bool { sources[slot].map { now >= $0.seen && now-$0.seen < 1 } ?? false }
}
