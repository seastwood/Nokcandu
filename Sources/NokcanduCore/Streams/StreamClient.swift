// SPDX-License-Identifier: GPL-3.0-only
// The GameStream host API (Sunshine, and NVIDIA GameStream before it): server info, apps, pairing, launch and quit.
// Pairing follows Moonlight/VoidLink's PairManager.
import Foundation
import CryptoKit
import NokcanduStreamCore

/// What a host says about itself (`/serverinfo`).
public struct StreamServerInfo: Equatable, Sendable {
    public var hostname = ""
    public var uniqueID = ""
    public var appVersion = ""
    public var gfeVersion = ""
    public var paired = false
    /// Over plain HTTP an unpaired host can't say whether we're paired; only HTTPS answers count.
    public var pairStatusKnown = false
    /// The host refused our certificate over HTTPS (it was unpaired on the host, or its pairings were reset).
    public var certificateRejected = false
    public var currentGame = 0
    public var state = ""
    public var httpsPort: UInt16 = 0
    public var externalPort: UInt16 = 0
    public var macAddress: String?
    public var localIP: String?
    public var externalIP: String?
    public var codecModes = 0
    public var maxLumaPixelsHEVC = 0
    public init() {}

    public var busy: Bool { state.hasSuffix("_SERVER_BUSY") }
    public var majorVersion: Int { Int(appVersion.split(separator: ".").first ?? "") ?? 0 }

    public init(xml: StreamXML) {
        hostname = xml["hostname"] ?? ""
        uniqueID = xml["uniqueid"] ?? ""
        appVersion = xml["appversion"] ?? ""
        gfeVersion = xml["GfeVersion"] ?? ""
        paired = xml["PairStatus"] == "1"
        currentGame = Int(xml["currentgame"] ?? "") ?? 0
        state = xml["state"] ?? ""
        httpsPort = UInt16(xml["HttpsPort"] ?? "") ?? 0
        externalPort = UInt16(xml["ExternalPort"] ?? "") ?? 0
        macAddress = xml["mac"]
        localIP = xml["LocalIP"]
        externalIP = xml["ExternalIP"]
        codecModes = Int(xml["ServerCodecModeSupport"] ?? "") ?? 0
        maxLumaPixelsHEVC = Int(xml["MaxLumaPixelsHEVC"] ?? "") ?? 0
    }
}

/// A host's XML answer: its status, its top-level fields, and repeated `<App>` records.
public struct StreamXML: Sendable {
    public var statusCode = 0
    public var statusMessage = ""
    public var fields: [String: String] = [:]
    public var records: [[String: String]] = []

    public subscript(_ key: String) -> String? { fields[key] }

    public init(data: Data, record: String = "App") {
        let d = Delegate(record: record)
        let p = XMLParser(data: Self.utf8(data))
        p.delegate = d
        p.parse()
        statusCode = d.status; statusMessage = d.message; fields = d.fields; records = d.records
    }

    /// Some hosts label their UTF-8 answer as UTF-16, which XMLParser then refuses.
    private static func utf8(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        s = s.replacingOccurrences(of: "encoding=\"UTF-16\"", with: "encoding=\"UTF-8\"", options: .caseInsensitive)
        return Data(s.utf8)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let record: String
        var status = 0, message = ""
        var fields: [String: String] = [:], records: [[String: String]] = []
        var current: [String: String]?
        var text = ""
        init(record: String) { self.record = record }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "root" {
                status = Int(attributes["status_code"] ?? "") ?? 0
                message = attributes["status_message"] ?? ""
            } else if name == record { current = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == record, let c = current { records.append(c); current = nil }
            else if current != nil { current?[name] = value }
            else if name != "root", fields[name] == nil { fields[name] = value }
            text = ""
        }
    }
}

/// This Mac's identity to hosts: its certificate and key, made once and kept in Application Support
/// (readable only by you). Hosts remember the certificate when you pair.
public struct StreamIdentity: Sendable {
    public let certificatePEM: String
    public let keyPEM: String
    /// Moonlight clients all send this ID; hosts tell clients apart by certificate.
    public static let uniqueID = "0123456789ABCDEF"

    public static var folder: URL { NokPaths.support.appendingPathComponent("Streams", isDirectory: true) }

    public static func loadOrCreate(in folder: URL = folder) throws -> StreamIdentity {
        let certURL = folder.appendingPathComponent("client.pem"), keyURL = folder.appendingPathComponent("client.key")
        if let c = try? String(contentsOf: certURL, encoding: .utf8), let k = try? String(contentsOf: keyURL, encoding: .utf8),
           c.contains("BEGIN CERTIFICATE"), k.contains("PRIVATE KEY") {
            return StreamIdentity(certificatePEM: c, keyPEM: k)
        }
        let id = try generate()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try id.keyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try id.certificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
        return id
    }

    public static func generate() throws -> StreamIdentity {
        var cert = [CChar](repeating: 0, count: 8192), key = [CChar](repeating: 0, count: 8192)
        guard nk_generate_identity(&cert, cert.count, &key, key.count) == 0 else { throw StreamError.crypto("couldn't make this Mac's certificate") }
        return StreamIdentity(certificatePEM: String(cString: cert), keyPEM: String(cString: key))
    }
}

public enum StreamError: LocalizedError, Equatable {
    case unreachable(String)
    case timeout
    case cancelled
    case tls
    case tlsDetail(String)
    case secureTimeout
    case wrongCertificate
    case http(Int, String)
    case host(String)
    case crypto(String)
    case pairing(String)
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Couldn't reach the host (\(why))."
        case .timeout: "The host didn't answer in time."
        case .cancelled: "Cancelled."
        case .tls: "Couldn't make a secure connection to the host."
        case .tlsDetail(let d): "Couldn't make a secure connection to the host (\(d))."
        case .secureTimeout: "The host's secure port (47984) takes connections but doesn't answer. Restart Sunshine on the host and try again."
        case .wrongCertificate: "The host's certificate has changed since you paired. Pair with it again."
        case .http(let code, let msg): msg.isEmpty ? "The host answered with error \(code)." : "\(msg) (\(code))"
        case .host(let msg): msg
        case .crypto(let what): "Encryption failed: \(what)."
        case .pairing(let msg): msg
        case .notPaired: "This Mac isn't paired with the host."
        }
    }
}

/// Requests to one host address. Blocking: call from a background task.
public final class StreamClient: @unchecked Sendable {
    public let host: String
    public let httpPort: UInt16
    public var httpsPort: UInt16
    public let identity: StreamIdentity
    /// The host's certificate (DER) once paired: HTTPS requests require exactly it.
    public var serverCertificate: Data?
    public var deviceName = Host.current().localizedName ?? "Mac"
    private let cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    public init(address: String, httpPort: UInt16 = 47989, httpsPort: UInt16 = 47984, identity: StreamIdentity, serverCertificate: Data? = nil) {
        let parts = StreamAddress.split(address)
        host = parts.host
        self.httpPort = parts.port ?? httpPort
        // A typed port is the HTTP port; Sunshine puts HTTPS five below it.
        self.httpsPort = parts.port.map { $0 &- 5 } ?? httpsPort
        self.identity = identity
        self.serverCertificate = serverCertificate
        cancelFlag.pointee = 0
    }
    deinit { cancelFlag.deallocate() }

    public func cancel() { cancelFlag.pointee = 1 }

    /// Where request failures are reported (the app's stream log).
    nonisolated(unsafe) public static var log: ((String) -> Void)?

    // MARK: Requests

    public func get(_ path: String, https: Bool, timeout: TimeInterval = 10, pin: Bool = true) throws -> (Data, peer: Data?) {
        try request("GET", path, https: https, timeout: timeout, pin: pin)
    }

    public func request(_ method: String, _ path: String, body: Data = Data(), https: Bool, timeout: TimeInterval = 10, pin: Bool = true) throws -> (Data, peer: Data?) {
        let port = https ? httpsPort : httpPort
        let pinned = pin ? serverCertificate : nil
        let pinnedBytes = pinned.map(Array.init) ?? []
        let bodyBytes = Array(body)
        let r: nk_http_result = path.withCString { p in
            host.withCString { h in
                identity.certificatePEM.withCString { c in
                    identity.keyPEM.withCString { k in
                        method.withCString { m in
                            pinnedBytes.withUnsafeBufferPointer { pb in
                                bodyBytes.withUnsafeBufferPointer { bb in
                                    nk_http_request(m, h, port, p, https ? 1 : 0, c, k, pb.isEmpty ? nil : pb.baseAddress, pb.count,
                                                    bb.isEmpty ? nil : bb.baseAddress, bb.count, "text/plain; charset=utf-8",
                                                    Int32(timeout * 1000), cancelFlag)
                                }
                            }
                        }
                    }
                }
            }
        }
        var result = r
        defer { nk_http_free(&result) }
        switch r.error {
        case 0: break
        case Int32(NK_HTTP_ERR_RESOLVE): throw StreamError.unreachable("unknown name")
        case Int32(NK_HTTP_ERR_CONNECT): throw StreamError.unreachable("no answer on port \(port)")
        case Int32(NK_HTTP_ERR_TIMEOUT): throw StreamError.timeout
        case Int32(NK_HTTP_ERR_CANCELLED): throw StreamError.cancelled
        case Int32(NK_HTTP_ERR_TLS):
            let text = withUnsafeBytes(of: r.tlsMessage) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if r.tlsCode == -0x6800 {      // MBEDTLS_ERR_SSL_TIMEOUT: the port took the connection but never answered
                StreamClient.log?("TLS handshake timed out (\(host):\(port))")
                throw StreamError.secureTimeout
            }
            let detail = "TLS \(String(format: "-0x%04X", -Int(r.tlsCode))) \(text) (\(host):\(port))"
            StreamClient.log?(detail)
            throw StreamError.tlsDetail(detail)
        case Int32(NK_HTTP_ERR_PINNED): throw StreamError.wrongCertificate
        default: throw StreamError.unreachable("the connection dropped")
        }
        let body = r.body.map { Data(bytes: $0, count: r.bodyLen) } ?? Data()
        let peer = r.peerCert.map { Data(bytes: $0, count: r.peerCertLen) }
        if r.status != 200 { throw StreamError.http(Int(r.status), String(data: body, encoding: .utf8).map { StreamXML(data: Data($0.utf8)).statusMessage } ?? "") }
        return (body, peer)
    }

    private func xml(_ path: String, https: Bool, timeout: TimeInterval = 10, record: String = "App") throws -> StreamXML {
        let x = StreamXML(data: try get(path, https: https, timeout: timeout).0, record: record)
        if x.statusCode != 200 && x.statusCode != 0 { throw StreamError.http(x.statusCode, x.statusMessage) }
        return x
    }

    private var q: String { "uniqueid=\(StreamIdentity.uniqueID)&uuid=\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())" }

    /// Over HTTPS when paired (which also confirms the pairing), else plain HTTP. A failed HTTPS check never
    /// counts as "unpaired" by itself: only the host refusing our certificate (401) is reported, as
    /// `certificateRejected`, and even then the saved pairing is kept for the user to decide.
    public func serverInfo(timeout: TimeInterval = 5) throws -> StreamServerInfo {
        var rejected = false
        if serverCertificate != nil {
            do {
                var info = StreamServerInfo(xml: try xml("/serverinfo?\(q)", https: true, timeout: timeout))
                info.pairStatusKnown = true
                return info
            } catch StreamError.http(401, _) {
                rejected = true
            } catch StreamError.tls, StreamError.tlsDetail(_) {
                // A dropped or refused handshake (a busy host, a changed HTTPS port): ask over HTTP for now.
            }
        }
        var info = StreamServerInfo(xml: try xml("/serverinfo?\(q)", https: false, timeout: timeout))
        info.pairStatusKnown = false
        info.certificateRejected = rejected
        if info.httpsPort > 0 { httpsPort = info.httpsPort }
        return info
    }

    /// For a host whose saved certificate was lost on this Mac: when the host still accepts our certificate
    /// (it answers HTTPS saying we're paired), returns its certificate so the pairing can be restored without a PIN.
    public func recoverPairing(timeout: TimeInterval = 4) -> Data? {
        guard let (body, peer) = try? get("/serverinfo?\(q)", https: true, timeout: timeout, pin: false), let peer else { return nil }
        let info = StreamServerInfo(xml: StreamXML(data: body))
        return info.paired && !info.uniqueID.isEmpty ? peer : nil
    }

    public func apps() throws -> [StreamApp] {
        guard serverCertificate != nil else { throw StreamError.notPaired }
        return try xml("/applist?\(q)", https: true).records.compactMap { r in
            guard let id = Int(r["ID"] ?? ""), let name = r["AppTitle"] else { return nil }
            return StreamApp(id: id, name: name, supportsHDR: r["IsHdrSupported"] == "1")
        }
    }

    /// The app's box art (PNG), if the host has one.
    public func appArt(_ id: Int) throws -> Data {
        try get("/appasset?\(q)&appid=\(id)&AssetType=2&AssetIdx=0", https: true).0
    }

    public struct Launch: Sendable {
        public var appID: Int
        public var width: Int, height: Int, fps: Int
        public var optimizeGameSettings: Bool
        public var riKey: Data
        public var riKeyID: Int32
        public var hdr: Bool
        public var playAudioOnHost: Bool
        public var surroundAudioInfo: Int
        public var gamepadMask: Int
        public var multiController: Bool
        public var resume: Bool
        public init(appID: Int, width: Int, height: Int, fps: Int, optimizeGameSettings: Bool, riKey: Data, riKeyID: Int32, hdr: Bool,
                    playAudioOnHost: Bool, surroundAudioInfo: Int, gamepadMask: Int, multiController: Bool, resume: Bool) {
            self.appID = appID; self.width = width; self.height = height; self.fps = fps; self.optimizeGameSettings = optimizeGameSettings
            self.riKey = riKey; self.riKeyID = riKeyID; self.hdr = hdr; self.playAudioOnHost = playAudioOnHost
            self.surroundAudioInfo = surroundAudioInfo; self.gamepadMask = gamepadMask; self.multiController = multiController; self.resume = resume
        }
    }

    /// Starts (or resumes) the app; returns the RTSP session URL when the host gives one.
    public func launch(_ l: Launch, isSunshine: Bool) throws -> String? {
        // Over 60 fps, old GeForce Experience hosts fell back to 720p60 unless asked for 0; Sunshine takes the real rate.
        let fps = l.fps > 60 && !isSunshine ? 0 : l.fps
        let hdr = l.hdr ? "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0" : ""
        let extra = String(cString: LiGetLaunchUrlQueryParameters())
        let path = "/\(l.resume ? "resume" : "launch")?\(q)&appid=\(l.appID)&mode=\(l.width)x\(l.height)x\(fps)&additionalStates=1&sops=\(l.optimizeGameSettings ? 1 : 0)"
            + "&rikey=\(l.riKey.hex)&rikeyid=\(l.riKeyID)\(hdr)&localAudioPlayMode=\(l.playAudioOnHost ? 1 : 0)&surroundAudioInfo=\(l.surroundAudioInfo)"
            + "&remoteControllersBitmap=\(l.gamepadMask)&gcmap=\(l.gamepadMask)&gcpersist=\(l.multiController ? 0 : 1)\(extra)"
        let x = try xml(path, https: true, timeout: 120)
        let ok = l.resume ? x["resume"] : x["gamesession"]
        if ok == nil || ok == "0" { throw StreamError.host(x.statusMessage.isEmpty ? "The host couldn't start \(l.resume ? "resuming" : "the app")." : x.statusMessage) }
        return x["sessionUrl0"]
    }

    /// Quits the app running on the host.
    public func quit() throws {
        let x = try xml("/cancel?\(q)", https: true, timeout: 30)
        if x["cancel"] == "0" { throw StreamError.host("The host didn't quit the app. Another device may have started it.") }
    }

    // MARK: Clipboard (Apollo)

    /// The host's clipboard text. Apollo only: needs the client's "read clipboard" permission and a running stream.
    public func hostClipboard() throws -> String {
        do { return String(decoding: try get("/actions/clipboard?\(q)&type=text", https: true, timeout: 5).0, as: UTF8.self) }
        catch let e as StreamError { throw Self.clipboardError(e, reading: true) }
    }

    /// Puts text on the host's clipboard. Apollo only: needs the client's "set clipboard" permission and a running stream.
    public func setHostClipboard(_ text: String) throws {
        do { _ = try request("POST", "/actions/clipboard?\(q)&type=text", body: Data(text.utf8), https: true, timeout: 5) }
        catch let e as StreamError { throw Self.clipboardError(e, reading: false) }
    }

    static func clipboardError(_ e: StreamError, reading: Bool) -> StreamError {
        switch e {
        case .http(404, _): return .host("This host doesn't share its clipboard. Clipboard sync needs Apollo (a Sunshine version) on the host.")
        case .http(401, _): return .host("The host doesn't allow this Mac to \(reading ? "read" : "set") its clipboard. In Apollo's web page, open this client under Device Management and turn on clipboard permissions.")
        case .http(403, _): return .host("The clipboard can only be shared during a stream.")
        default: return e
        }
    }

    /// VoidLink hosts can change the bitrate during a stream.
    public func changeBitrate(kbps: Int) throws {
        _ = try get("/bitrate?\(q)&clientname=\(deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac")&bitrate=\(kbps)", https: true)
    }

    public func unpair() { _ = try? get("/unpair?\(q)", https: false, timeout: 5) }

    // MARK: Pairing

    /// Pairs with a PIN the user types into the host (Sunshine's web page → PIN). Returns the host's certificate (DER).
    /// Blocks while the host waits for the PIN, up to two minutes.
    public func pair(pin: String) throws -> Data {
        let info = try serverInfo()
        if info.busy { throw StreamError.pairing("The host is streaming to another device. Quit that stream on the host, then pair.") }
        let sha256 = info.majorVersion >= 7
        func hash(_ d: Data) -> Data { sha256 ? Data(SHA256.hash(data: d)) : Data(Insecure.SHA1.hash(data: d)) }
        let hashLength = sha256 ? 32 : 20

        let salt = try Self.random(16)
        let aesKey = hash(salt + Data(pin.utf8)).prefix(16)
        let name = deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac"
        let base = "/pair?\(q)&devicename=\(name)&updateState=1"

        // 1. Send our certificate; the host shows a PIN prompt and answers with its certificate once the PIN is entered.
        let step1 = try xml("\(base)&phrase=getservercert&salt=\(salt.hex)&clientcert=\(Data(identity.certificatePEM.utf8).hex)", https: false, timeout: 125)
        guard step1["paired"] == "1", let plain = step1["plaincert"], !plain.isEmpty, let serverPEM = Data(hex: plain) else {
            unpair()
            throw StreamError.pairing(step1["plaincert"] == nil && step1["paired"] == "1" ? "Another device is pairing with the host. Try again in a moment." : "The host declined pairing.")
        }
        let serverDER = try Self.der(serverPEM)

        // 2. Our challenge, encrypted with the PIN's key.
        let challenge = try Self.random(16)
        let step2 = try xml("\(base)&clientchallenge=\(try Self.aes(challenge, aesKey, encrypt: true).hex)", https: false)
        guard step2["paired"] == "1", let enc = step2["challengeresponse"].flatMap({ Data(hex: $0) }) else { unpair(); throw StreamError.pairing("Pairing stopped at step 2.") }
        let response = try Self.aes(enc, aesKey, encrypt: false)
        guard response.count >= hashLength + 16 else { unpair(); throw StreamError.pairing("The host's answer was malformed.") }
        let serverResponse = response.prefix(hashLength)
        let serverChallenge = response.subdata(in: hashLength..<(hashLength + 16))

        // 3. Answer the host's challenge with a hash over our certificate's signature and a secret of ours.
        let clientSecret = try Self.random(16)
        var answer = hash(serverChallenge + (try Self.signature(of: Data(identity.certificatePEM.utf8))) + clientSecret)
        answer.append(Data(count: 32 - answer.count))
        let step3 = try xml("\(base)&serverchallengeresp=\(try Self.aes(answer, aesKey, encrypt: true).hex)", https: false)
        guard step3["paired"] == "1", let secretResp = step3["pairingsecret"].flatMap({ Data(hex: $0) }), secretResp.count > 16 else {
            unpair(); throw StreamError.pairing("Pairing stopped at step 3.")
        }
        let serverSecret = secretResp.prefix(16), serverSignature = secretResp.dropFirst(16)

        // The host proves it knows the PIN, and that the certificate is really its own.
        guard Self.verify(serverSecret, signature: serverSignature, certificate: serverPEM) else { unpair(); throw StreamError.pairing("The host's certificate didn't check out.") }
        let expected = hash(challenge + (try Self.signature(of: serverPEM)) + serverSecret)
        guard expected == serverResponse else { unpair(); throw StreamError.pairing("Wrong PIN. Check the PIN you typed on the host and try again.") }

        // 4. Our signed secret.
        let signed = clientSecret + (try Self.sign(clientSecret, key: identity.keyPEM))
        let step4 = try xml("\(base)&clientpairingsecret=\(signed.hex)", https: false)
        guard step4["paired"] == "1" else { unpair(); throw StreamError.pairing("Pairing stopped at step 4.") }

        // 5. Confirm over HTTPS with the new certificates.
        serverCertificate = serverDER
        do {
            let step5 = try xml("\(base)&phrase=pairchallenge", https: true)
            guard step5["paired"] == "1" else { throw StreamError.pairing("Pairing stopped at step 5.") }
        } catch {
            serverCertificate = nil; unpair()
            throw (error as? StreamError).map { $0 == .cancelled ? $0 : StreamError.pairing("Pairing stopped at the secure check (\($0.localizedDescription))") } ?? error
        }
        return serverDER
    }

    /// A four-digit PIN for the user to type on the host.
    public static func newPIN() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

    // MARK: Crypto helpers

    static func random(_ n: Int) throws -> Data { try randomData(n) }
    /// Cryptographically random bytes.
    public static func randomData(_ n: Int) throws -> Data {
        var d = Data(count: n)
        let rc = d.withUnsafeMutableBytes { nk_random($0.bindMemory(to: UInt8.self).baseAddress, n) }
        if rc != 0 { throw StreamError.crypto("no random numbers") }
        return d
    }
    static func aes(_ data: Data, _ key: Data, encrypt: Bool) throws -> Data {
        var input = data
        if input.count % 16 != 0 { input.append(Data(count: 16 - input.count % 16)) }
        var out = Data(count: input.count)
        let k = Array(key.prefix(16))
        let rc = out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in
            nk_aes128_ecb(k, i.bindMemory(to: UInt8.self).baseAddress, input.count, o.bindMemory(to: UInt8.self).baseAddress, encrypt ? 1 : 0)
        } }
        if rc != 0 { throw StreamError.crypto("AES") }
        return out
    }
    static func signature(of cert: Data) throws -> Data {
        var out = Data(count: 1024), len = 1024
        let rc = out.withUnsafeMutableBytes { o in cert.withUnsafeBytes { c in
            nk_cert_signature(c.bindMemory(to: UInt8.self).baseAddress, cert.count, o.bindMemory(to: UInt8.self).baseAddress, &len)
        } }
        if rc != 0 { throw StreamError.crypto("certificate signature") }
        return out.prefix(len)
    }
    static func der(_ cert: Data) throws -> Data {
        var out = Data(count: 8192), len = 8192
        let rc = out.withUnsafeMutableBytes { o in cert.withUnsafeBytes { c in
            nk_cert_der(c.bindMemory(to: UInt8.self).baseAddress, cert.count, o.bindMemory(to: UInt8.self).baseAddress, &len)
        } }
        if rc != 0 { throw StreamError.pairing("The host sent a certificate that couldn't be read.") }
        return out.prefix(len)
    }
    static func sign(_ data: Data, key: String) throws -> Data {
        var out = Data(count: 1024), len = 1024
        let rc = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in
            nk_sign_sha256(key, d.bindMemory(to: UInt8.self).baseAddress, data.count, o.bindMemory(to: UInt8.self).baseAddress, &len)
        } }
        if rc != 0 { throw StreamError.crypto("signing") }
        return out.prefix(len)
    }
    static func verify(_ data: Data, signature: Data, certificate: Data) -> Bool {
        let d = Data(data), s = Data(signature)
        return certificate.withUnsafeBytes { c in d.withUnsafeBytes { db in s.withUnsafeBytes { sb in
            nk_verify_sha256(c.bindMemory(to: UInt8.self).baseAddress, certificate.count, db.bindMemory(to: UInt8.self).baseAddress, d.count,
                             sb.bindMemory(to: UInt8.self).baseAddress, s.count) == 0
        } } }
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var d = Data(capacity: chars.count / 2)
        func v(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        var i = 0
        while i < chars.count {
            guard let hi = v(chars[i]), let lo = v(chars[i + 1]) else { return nil }
            d.append(hi << 4 | lo); i += 2
        }
        self = d
    }
}
