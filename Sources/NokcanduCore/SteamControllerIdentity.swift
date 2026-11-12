import Foundation
import CryptoKit

/// Controller identity response, not the receiver's USB serial. Only a digest is retained.
public enum SteamControllerIdentity {
    public static var query: [UInt8] {
        var bytes=[UInt8](repeating:0,count:64)
        bytes[0]=0xae;bytes[1]=1;bytes[2]=1
        return bytes
    }
    public static func fingerprint(_ bytes:[UInt8]) -> String? {
        guard bytes.count>=4,bytes[0]==0xae,(2...21).contains(bytes[1]),bytes[2]==1,
              Int(bytes[1])+2<=bytes.count else{return nil}
        let serial=Array(bytes[3..<(Int(bytes[1])+2)].prefix(while:{$0 != 0}))
        guard (5...20).contains(serial.count),serial.allSatisfy({(0x21...0x7e).contains($0)}),
              Set(serial) != [UInt8(ascii:"X")], Set(serial) != [UInt8(ascii:"0")] else{return nil}
        return SHA256.hash(data:Data("Nokcandu original Steam Controller\0".utf8)+Data(serial)).map{String(format:"%02x",$0)}.joined()
    }
    public struct Recovery: Codable, Equatable {
        public let fingerprint: String
        public let original: SteamControllerMode.Settings
        public let applied: SteamControllerMode.Settings
        public init?(fingerprint:String,original:SteamControllerMode.Settings) {
            guard fingerprint.count==64,fingerprint.allSatisfy({$0.isHexDigit}),let applied=SteamControllerMode.captured(original) else{return nil}
            self.fingerprint=fingerprint;self.original=original;self.applied=applied
        }
        public func recoveredOriginal(identity:String,current:SteamControllerMode.Settings) -> SteamControllerMode.Settings? {
            guard identity==fingerprint,applied==SteamControllerMode.captured(original),current==applied else{return nil}
            return original
        }
    }
}
