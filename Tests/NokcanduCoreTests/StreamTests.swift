import XCTest
import CryptoKit
import Network
@testable import NokcanduCore
import NokcanduStreamCore
import NokcanduPadEngine

final class StreamCryptoTests: XCTestCase {
    func testIdentitySignsAndItsCertificateVerifies() throws {
        let id = try StreamIdentity.generate()
        XCTAssertTrue(id.certificatePEM.contains("BEGIN CERTIFICATE"))
        XCTAssertTrue(id.keyPEM.contains("PRIVATE KEY"))
        let message = Data("pairing secret".utf8)
        let signature = try StreamClient.sign(message, key: id.keyPEM)
        XCTAssertEqual(signature.count, 256, "RSA-2048")
        let pem = Data(id.certificatePEM.utf8)
        XCTAssertTrue(StreamClient.verify(message, signature: signature, certificate: pem))
        XCTAssertFalse(StreamClient.verify(Data("something else".utf8), signature: signature, certificate: pem))
        // The certificate's own signature and DER form, which pairing and pinning use.
        XCTAssertEqual(try StreamClient.signature(of: pem).count, 256)
        let der = try StreamClient.der(pem)
        XCTAssertEqual(der.first, 0x30, "a DER SEQUENCE")
        XCTAssertTrue(StreamClient.verify(message, signature: signature, certificate: der))
    }

    func testIdentityIsKeptAndPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try StreamIdentity.loadOrCreate(in: folder)
        let b = try StreamIdentity.loadOrCreate(in: folder)
        XCTAssertEqual(a.certificatePEM, b.certificatePEM, "made once")
        let perms = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("client.key").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testAESMatchesTheStandardVector() throws {
        // FIPS-197 appendix C.1.
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")!
        let plain = Data(hex: "00112233445566778899AABBCCDDEEFF")!
        let enc = try StreamClient.aes(plain, key, encrypt: true)
        XCTAssertEqual(enc.hex, "69C4E0D86A7B0430D8CDB78070B4C55A")
        XCTAssertEqual(try StreamClient.aes(enc, key, encrypt: false), plain)
    }

    func testHex() {
        XCTAssertEqual(Data([0x00, 0xAB, 0x7F]).hex, "00AB7F")
        XCTAssertEqual(Data(hex: "00ab7F"), Data([0x00, 0xAB, 0x7F]))
        XCTAssertNil(Data(hex: "abc"))
        XCTAssertNil(Data(hex: "zz"))
    }
}

final class StreamProtocolTests: XCTestCase {
    func testServerInfoFromSunshine() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>GAMING-PC</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion>
        <uniqueid>3A1B2C3D-0000</uniqueid><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><mac>AA:BB:CC:DD:EE:FF</mac>
        <MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC><LocalIP>192.168.1.20</LocalIP><ServerCodecModeSupport>3843</ServerCodecModeSupport>
        <PairStatus>1</PairStatus><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let info = StreamServerInfo(xml: StreamXML(data: Data(xml.utf8)))
        XCTAssertEqual(info.hostname, "GAMING-PC")
        XCTAssertEqual(info.uniqueID, "3A1B2C3D-0000")
        XCTAssertEqual(info.majorVersion, 7)
        XCTAssertTrue(info.paired)
        XCTAssertFalse(info.busy)
        XCTAssertEqual(info.httpsPort, 47984)
        XCTAssertEqual(info.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(info.codecModes, 3843)
        var caps = StreamHost.Capabilities(); caps.appVersion = info.appVersion
        XCTAssertTrue(caps.isSunshine)
    }

    func testAppListAndUTF16Label() {
        let xml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <root status_code="200"><App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>
        <App><IsHdrSupported>0</IsHdrSupported><AppTitle>Steam Big Picture</AppTitle><ID>1093255277</ID></App></root>
        """
        let x = StreamXML(data: Data(xml.utf8))
        XCTAssertEqual(x.statusCode, 200)
        XCTAssertEqual(x.records.count, 2)
        XCTAssertEqual(x.records[1]["AppTitle"], "Steam Big Picture")
        XCTAssertEqual(x.records[0]["IsHdrSupported"], "1")
    }

    func testErrorStatus() {
        let x = StreamXML(data: Data(#"<root status_code="401" status_message="The client is not authorized. Certificate verification failed."/>"#.utf8))
        XCTAssertEqual(x.statusCode, 401)
        XCTAssertTrue(x.statusMessage.hasPrefix("The client is not authorized"))
    }

    func testAddresses() {
        XCTAssertEqual(StreamAddress.split("192.168.1.2").host, "192.168.1.2")
        XCTAssertNil(StreamAddress.split("192.168.1.2").port)
        XCTAssertEqual(StreamAddress.split("pc.local:48989").port, 48989)
        XCTAssertEqual(StreamAddress.split("[fe80::1]:47989").host, "fe80::1")
        XCTAssertEqual(StreamAddress.split("[fe80::1]:47989").port, 47989)
        XCTAssertEqual(StreamAddress.split("2001:db8::5").host, "2001:db8::5", "a bare IPv6 address isn't host:port")
        XCTAssertTrue(StreamAddress.isPrivate("10.0.0.4"))
        XCTAssertTrue(StreamAddress.isPrivate("172.20.1.1"))
        XCTAssertTrue(StreamAddress.isPrivate("100.101.2.3"), "Tailscale's range")
        XCTAssertTrue(StreamAddress.isPrivate("gaming-pc.local"))
        XCTAssertFalse(StreamAddress.isPrivate("203.0.113.9"))
        XCTAssertFalse(StreamAddress.isPrivate("172.32.0.1"))
        // A typed port is the HTTP port; HTTPS is five below it.
        let c = StreamClient(address: "pc:48989", identity: StreamIdentity(certificatePEM: "", keyPEM: ""))
        XCTAssertEqual(c.httpPort, 48989); XCTAssertEqual(c.httpsPort, 48984)
    }

    func testMergeReplacesThePlaceholderAndKeepsProfiles() {
        var lib = StreamLibrary()
        var h = StreamHost(id: "manual:192.168.1.20", name: "192.168.1.20"); h.manualAddress = "192.168.1.20"
        lib.hosts = [h]
        lib.profiles = [StreamProfile(hostID: h.id, name: "Home")]
        var info = StreamServerInfo()
        info.uniqueID = "UUID-1"; info.hostname = "GAMING-PC"; info.externalIP = "203.0.113.9"; info.macAddress = "AA:BB:CC:DD:EE:FF"
        let id = lib.merge(info, reachedAt: "192.168.1.20", placeholder: h.id)
        XCTAssertEqual(id, "UUID-1")
        XCTAssertEqual(lib.hosts.count, 1)
        XCTAssertEqual(lib.hosts[0].name, "GAMING-PC")
        XCTAssertEqual(lib.hosts[0].localAddress, "192.168.1.20")
        XCTAssertEqual(lib.hosts[0].remoteAddress, "203.0.113.9")
        XCTAssertEqual(lib.profiles[0].hostID, "UUID-1")
        XCTAssertEqual(lib.hosts[0].candidates(.remote), ["203.0.113.9", "192.168.1.20"])
        // Seen again by its ID: still one host.
        lib.merge(info, reachedAt: "192.168.1.21")
        XCTAssertEqual(lib.hosts.count, 1)
        XCTAssertEqual(lib.hosts[0].localAddress, "192.168.1.21")
    }

    func testAFailedCheckNeverErasesThePairing() {
        var lib = StreamLibrary()
        var h = StreamHost(id: "U", name: "PC"); h.serverCertificate = "AAAA"
        lib.hosts = [h]
        var info = StreamServerInfo(); info.uniqueID = "U"; info.paired = false
        lib.merge(info, reachedAt: "10.0.0.2")
        info.pairStatusKnown = true; info.certificateRejected = true
        lib.merge(info, reachedAt: "10.0.0.2")
        XCTAssertTrue(lib.hosts[0].isPaired, "only the user drops a pairing (by pairing again or removing the host)")
    }

    func testStarterProfilePicksTheDesktop() {
        var lib = StreamLibrary()
        var h = StreamHost(id: "U", name: "PC")
        h.apps = [StreamApp(id: 1, name: "Steam Big Picture"), StreamApp(id: 2, name: "Desktop")]
        lib.hosts = [h]
        let p = lib.addStarterProfile(for: "U")
        XCTAssertEqual(p?.appID, 2)
        XCTAssertNil(lib.addStarterProfile(for: "U"), "only for a host with no profiles yet")
    }

    func testOlderSavedProfilesDecodeWithDefaults() throws {
        let json = #"{"id":"a","hostID":"h","name":"Home","video":{"fps":120}}"#
        let p = try JSONDecoder().decode(StreamProfile.self, from: Data(json.utf8))
        XCTAssertEqual(p.video.fps, 120)
        XCTAssertEqual(p.video.codec, .automatic)
        XCTAssertEqual(p.controller.sendAs, .automatic)
        XCTAssertEqual(p.input.mouse, .capture)
        XCTAssertTrue(p.optimizeGameSettings)
        XCTAssertNil(p.audio.outputDevice, "the Mac's default output unless chosen")
        // And round trips, routes included.
        var q = p; q.route = .manual("pc:48989")
        XCTAssertEqual(try JSONDecoder().decode(StreamProfile.self, from: JSONEncoder().encode(q)), q)
    }

    func testDefaultBitrates() {
        typealias V = StreamProfile.Video
        XCTAssertEqual(V.defaultBitrate(width: 1280, height: 720, fps: 60), 10_000)
        XCTAssertEqual(V.defaultBitrate(width: 1920, height: 1080, fps: 60), 20_000)
        XCTAssertEqual(V.defaultBitrate(width: 3840, height: 2160, fps: 60), 80_000)
        XCTAssertEqual(V.defaultBitrate(width: 1920, height: 1080, fps: 30), 10_000)
        XCTAssertGreaterThan(V.defaultBitrate(width: 1920, height: 1080, fps: 120), 20_000)
        XCTAssertLessThan(V.defaultBitrate(width: 1920, height: 1080, fps: 120), 40_000, "slower above 60 fps")
        XCTAssertEqual(V.defaultBitrate(width: 7680, height: 4320, fps: 120, yuv444: true), 150_000, "capped")
    }

    func testKeys() {
        XCTAssertEqual(StreamKeys.windowsKey(0x00), 0x41)   // A
        XCTAssertEqual(StreamKeys.windowsKey(0x24), 0x0D)   // Return
        XCTAssertEqual(StreamKeys.windowsKey(0x35), 0x1B)   // Escape
        XCTAssertEqual(StreamKeys.windowsKey(0x37), 0x5B)   // ⌘ → Windows
        XCTAssertEqual(StreamKeys.windowsKey(0x7E), 0x26)   // up
        XCTAssertEqual(StreamKeys.windowsKey(0x7A), 0x70)   // F1
        XCTAssertNil(StreamKeys.windowsKey(0x7F))
        // Every Windows code is unique for the main keys (letters and digits).
        let letters = (0..<0x80).compactMap { StreamKeys.windowsKey($0) }.filter { (0x30...0x5A).contains($0) }
        XCTAssertEqual(Set(letters).count, 36)
    }
}

final class StreamAV1Tests: XCTestCase {
    private struct Bits {
        var bytes: [UInt8] = [], n = 0
        mutating func put(_ v: Int, _ bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if n % 8 == 0 { bytes.append(0) }
                if (v >> i) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (n % 8)) }
                n += 1
            }
        }
    }

    func testSequenceHeaderGivesSizeDepthAndColour() {
        var b = Bits()
        b.put(0, 3); b.put(0, 1); b.put(0, 1)          // profile 0, not still, not reduced
        b.put(0, 1); b.put(0, 1)                        // no timing info, no initial display delay
        b.put(0, 5)                                     // one operating point
        b.put(0, 12); b.put(8, 5); b.put(0, 1)          // idc, level 8 (4.0), main tier
        b.put(11, 4); b.put(10, 4)                      // width bits 12, height bits 11
        b.put(1919, 12); b.put(1079, 11)
        b.put(0, 1)                                     // no frame IDs
        b.put(0, 1); b.put(1, 1); b.put(1, 1)           // 64×64 superblocks, filter intra, intra edge
        b.put(0, 1); b.put(0, 1); b.put(0, 1); b.put(0, 1)
        b.put(1, 1); b.put(0, 1); b.put(0, 1)           // order hint on
        b.put(1, 1)                                     // choose screen content tools → forced = 2
        b.put(1, 1)                                     // choose integer mv
        b.put(6, 3)                                     // order hint bits
        b.put(0, 1); b.put(1, 1); b.put(1, 1)           // superres, cdef, restoration
        b.put(1, 1)                                     // high bit depth: 10-bit
        b.put(0, 1)                                     // not monochrome
        b.put(1, 1); b.put(9, 8); b.put(16, 8); b.put(9, 8)   // BT.2020, PQ, BT.2020 matrix
        b.put(0, 1)                                     // limited range
        b.put(0, 2)                                     // chroma sample position
        b.put(0, 1)                                     // separate uv delta q
        b.put(0, 1)                                     // film grain
        let payload = b.bytes
        // A temporal delimiter OBU, then the sequence header OBU, then a frame OBU stub.
        var tu: [UInt8] = [0x12, 0x00]
        tu += [0x0A, UInt8(payload.count)] + payload
        tu += [0x32, 0x02, 0xAA, 0xBB]
        var seq = nk_av1_sequence()
        XCTAssertEqual(nk_av1_parse(tu, tu.count, &seq), 0)
        XCTAssertEqual(seq.width, 1920); XCTAssertEqual(seq.height, 1080)
        XCTAssertEqual(seq.bitDepth, 10)
        XCTAssertEqual(seq.level, 8)
        XCTAssertEqual(seq.colorPrimaries, 9); XCTAssertEqual(seq.transferCharacteristics, 16)
        XCTAssertEqual(seq.subsamplingX, 1); XCTAssertEqual(seq.subsamplingY, 1)
        let av1c = withUnsafeBytes(of: seq.av1c) { Array($0.prefix(seq.av1cLength)) }
        XCTAssertEqual(Array(av1c.prefix(4)), [0x81, 0x08, 0x4C, 0x00], "marker/version, profile 0 level 8, 10-bit 4:2:0")
        XCTAssertEqual(Array(av1c[4...5]), [0x0A, UInt8(payload.count)], "the sequence header OBU follows")
        XCTAssertEqual(Array(av1c.suffix(payload.count)), payload)
    }

    func testNoSequenceHeader() {
        let tu: [UInt8] = [0x12, 0x00, 0x32, 0x02, 0xAA, 0xBB]
        var seq = nk_av1_sequence()
        XCTAssertNotEqual(nk_av1_parse(tu, tu.count, &seq), 0)
    }
}

/// nk_http_get against a tiny local server: Content-Length, chunked and closed-connection answers.
final class StreamHTTPTests: XCTestCase {
    private func serve(_ response: String) throws -> (UInt16, () -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        let t = Thread {
            let c = accept(fd, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = recv(c, &buf, buf.count, 0)
            let bytes = Array(response.utf8)
            _ = send(c, bytes, bytes.count, 0)
            close(c)
        }
        t.start()
        return (port, { close(fd) })
    }

    private func get(_ response: String) throws -> nk_http_result {
        let (port, stop) = try serve(response)
        defer { stop() }
        return nk_http_get("127.0.0.1", port, "/serverinfo?uniqueid=0123456789ABCDEF", 0, nil, nil, nil, 0, 3000, nil)
    }

    func testContentLength() throws {
        var r = try get("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\n<root></root>")
        defer { nk_http_free(&r) }
        XCTAssertEqual(r.error, 0); XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(cString: r.body), "<root></root>")
    }

    func testChunked() throws {
        var r = try get("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\n<root>\r\n7\r\n</root>\r\n0\r\n\r\n")
        defer { nk_http_free(&r) }
        XCTAssertEqual(String(cString: r.body), "<root></root>")
    }

    func testClosedConnectionAndErrorStatus() throws {
        var r = try get("HTTP/1.1 404 Not Found\r\n\r\nnope")
        defer { nk_http_free(&r) }
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(String(cString: r.body), "nope")
    }

    func testNothingListening() {
        var r = nk_http_get("127.0.0.1", 9, "/", 0, nil, nil, nil, 0, 1000, nil)
        defer { nk_http_free(&r) }
        XCTAssertLessThan(r.error, 0)
    }
}

/// Pairing against a fake host that does the host's half of the PIN exchange (steps 1–4 over HTTP).
/// Its HTTPS port has nothing on it, so a correct exchange ends at the final secure check.
final class StreamPairingTests: XCTestCase {
    private final class FakeHost: @unchecked Sendable {
        let pin: String
        let identity: StreamIdentity
        var aesKey = Data(), serverChallenge = Data(), serverSecret = Data(), clientCert = Data(), clientHash = Data()
        var log: [String] = []
        var clientVerified = false
        init(pin: String) throws { self.pin = pin; identity = try StreamIdentity.generate() }

        func answer(_ path: String) -> String {
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(string: path)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            func ok(_ fields: String) -> String { "<root status_code=\"200\">\(fields)</root>" }
            if path.hasPrefix("/serverinfo") {
                return ok("<hostname>FAKE</hostname><uniqueid>FAKE-1</uniqueid><appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state>")
            }
            if q["phrase"] == "getservercert" {
                log.append("getservercert")
                aesKey = Data(SHA256.hash(data: Data(hex: q["salt"]!)! + Data(pin.utf8))).prefix(16)
                clientCert = Data(hex: q["clientcert"]!)!
                return ok("<paired>1</paired><plaincert>\(Data(identity.certificatePEM.utf8).hex)</plaincert>")
            }
            if let c = q["clientchallenge"] {
                log.append("clientchallenge")
                let challenge = try! StreamClient.aes(Data(hex: c)!, aesKey, encrypt: false)
                serverChallenge = try! StreamClient.randomData(16); serverSecret = try! StreamClient.randomData(16)
                let hash = Data(SHA256.hash(data: challenge + (try! StreamClient.signature(of: Data(identity.certificatePEM.utf8))) + serverSecret))
                return ok("<paired>1</paired><challengeresponse>\(try! StreamClient.aes(hash + serverChallenge, aesKey, encrypt: true).hex)</challengeresponse>")
            }
            if let r = q["serverchallengeresp"] {
                log.append("serverchallengeresp")
                clientHash = try! StreamClient.aes(Data(hex: r)!, aesKey, encrypt: false).prefix(32)
                let signed = serverSecret + (try! StreamClient.sign(serverSecret, key: identity.keyPEM))
                return ok("<paired>1</paired><pairingsecret>\(signed.hex)</pairingsecret>")
            }
            if let s = q["clientpairingsecret"] {
                log.append("clientpairingsecret")
                let d = Data(hex: s)!
                let secret = d.prefix(16), signature = d.dropFirst(16)
                let expected = Data(SHA256.hash(data: serverChallenge + (try! StreamClient.signature(of: clientCert)) + secret))
                clientVerified = StreamClient.verify(Data(secret), signature: Data(signature), certificate: clientCert) && expected == clientHash
                return ok("<paired>\(clientVerified ? 1 : 0)</paired>")
            }
            if path.hasPrefix("/unpair") { log.append("unpair"); return ok("") }
            return "<root status_code=\"404\"/>"
        }
    }

    private func run(clientPIN: String, hostPIN: String) throws -> (FakeHost, Error?) {
        let host = try FakeHost(pin: hostPIN)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        let t = Thread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 65536), got = 0
                while got < buf.count {
                    let n = recv(c, &buf[got], buf.count - got, 0)
                    if n <= 0 { break }
                    got += n
                    if String(decoding: buf[..<got], as: UTF8.self).contains("\r\n\r\n") { break }
                }
                let request = String(decoding: buf[..<got], as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = host.answer(path)
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                _ = response.withCString { send(c, $0, strlen($0), 0) }
                close(c)
            }
        }
        t.start()
        defer { close(fd) }
        let client = StreamClient(address: "127.0.0.1:\(port)", identity: try StreamIdentity.generate())
        do { _ = try client.pair(pin: clientPIN); return (host, nil) } catch { return (host, error) }
    }

    func testTheRightPINGetsThroughEveryStep() throws {
        let (host, error) = try run(clientPIN: "4821", hostPIN: "4821")
        XCTAssertEqual(Array(host.log.prefix(4)), ["getservercert", "clientchallenge", "serverchallengeresp", "clientpairingsecret"])
        XCTAssertTrue(host.clientVerified, "the host can check our signed secret and hash")
        // Nothing serves HTTPS here, so it stops at the final secure check (and unpairs).
        XCTAssertTrue((error as? StreamError).map { if case .pairing(let m) = $0 { return m.contains("secure check") } else { return false } } ?? false, "\(String(describing: error))")
        XCTAssertEqual(host.log.last, "unpair")
    }

    func testAWrongPINIsCaught() throws {
        let (host, error) = try run(clientPIN: "1111", hostPIN: "2222")
        XCTAssertEqual(error as? StreamError, .pairing("Wrong PIN. Check the PIN you typed on the host and try again."))
        XCTAssertFalse(host.log.contains("clientpairingsecret"), "our secret isn't sent to a host that didn't prove the PIN")
    }
}

/// The streaming core's AES-CBC (audio) on Mbed TLS: NIST SP 800-38A F.2.1, then a padded round trip.
final class StreamCoreCryptoTests: XCTestCase {
    func testCBCDecryptsAPaddedNISTBlock() throws {
        let key = Data(hex: "2B7E151628AED2A6ABF7158809CF4F3C")!
        let iv = Data(hex: "000102030405060708090A0B0C0D0E0F")!
        let plain = Data(hex: "6BC1BEE22E409F96E93D7E117393172A")!
        // CBC by hand: c1 = E(p1 ⊕ iv) (NIST's block), c2 = E(padding ⊕ c1).
        let c1 = try StreamClient.aes(Data(zip(plain, iv).map { $0 ^ $1 }), key, encrypt: true)
        XCTAssertEqual(c1.hex, "7649ABAC8119B246CEE98E9B12E9197D")
        let c2 = try StreamClient.aes(Data(zip([UInt8](repeating: 16, count: 16), c1).map { $0 ^ $1 }), key, encrypt: true)
        let cipher = Array(c1 + c2)
        var dec = [UInt8](repeating: 0, count: 64); var decLen: Int32 = 64
        XCTAssertEqual(nk_selftest_cbc(&dec, &decLen, Array(key), Array(iv), cipher, Int32(cipher.count)), 0)
        XCTAssertEqual(Array(dec.prefix(Int(decLen))), Array(plain))
        // The core's encryption pads only up to a whole block (a full block gets none), then encrypts: NIST's block.
        var enc = [UInt8](repeating: 0, count: 64); var encLen: Int32 = 64
        var input = Array(plain) + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(nk_selftest_cbc_encrypt(&enc, &encLen, Array(key), Array(iv), &input, Int32(plain.count)), 0)
        XCTAssertEqual(Array(enc.prefix(Int(encLen))), Array(c1))
    }
}

final class VBANTests: XCTestCase {
    func testHeaderMatchesTheVBANSpecification() {
        let p = VBANPacketizer(streamName: "Stream1", sampleRate: 48000, channels: 1)
        let h = p.header(samples: 256)
        XCTAssertEqual(Array(h[0..<4]), Array("VBAN".utf8))
        XCTAssertEqual(h[4], 3, "48 kHz is index 3, audio sub-protocol 0")
        XCTAssertEqual(h[5], 255, "samples per frame minus one")
        XCTAssertEqual(h[6], 0, "channels minus one")
        XCTAssertEqual(h[7], 1, "16-bit PCM")
        XCTAssertEqual(Array(h[8..<15]), Array("Stream1".utf8))
        XCTAssertEqual(Array(h[15..<24]), [UInt8](repeating: 0, count: 9), "name padded with zeros")
        XCTAssertEqual(VBANPacketizer(streamName: "x", sampleRate: 44100, channels: 2).header(samples: 1)[4], 16)
    }

    func testPacketsCarry256SamplesAndCount() {
        var p = VBANPacketizer(streamName: "Mic", sampleRate: 48000, channels: 2)
        XCTAssertEqual(p.samplesPerPacket, 256)
        XCTAssertTrue(p.packets(adding: [Int16](repeating: 1, count: 300)).isEmpty, "waits for a whole packet")
        let samples = (0..<(256 * 2 - 300)).map { Int16(truncatingIfNeeded: $0 &* 77 - 20000) }
        let packets = p.packets(adding: samples)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].count, 28 + 256 * 2 * 2)
        XCTAssertEqual(Array(packets[0][24..<28]), [0, 0, 0, 0], "the first frame is number 0")
        let more = p.packets(adding: [Int16](repeating: -2, count: 512))
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(Array(more[0][24..<28]), [1, 0, 0, 0])
        XCTAssertEqual(Array(more[0].suffix(2)), [0xFE, 0xFF], "little-endian samples")
    }

    func testOlderProfilesHaveVBANOff() throws {
        let p = try JSONDecoder().decode(StreamProfile.self, from: Data(#"{"id":"a","hostID":"h","name":"Home","audio":{"channels":"stereo"}}"#.utf8))
        XCTAssertFalse(p.audio.vban.enabled)
        XCTAssertEqual(p.audio.vban.port, 6980)
    }
}

final class StreamClipboardTests: XCTestCase {
    func testPostSendsItsBody() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        defer { close(fd) }
        final class Box: @unchecked Sendable { var request = "" }
        let box = Box(), done = expectation(description: "request")
        Thread {
            let c = accept(fd, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096), got = 0
            while got < buf.count {
                let n = recv(c, &buf[got], buf.count - got, 0); if n <= 0 { break }; got += n
                let s = String(decoding: buf[..<got], as: UTF8.self)
                if s.contains("\r\n\r\n"), s.hasSuffix("héllo ✓") { break }
            }
            box.request = String(decoding: buf[..<got], as: UTF8.self)
            let ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            _ = ok.withCString { send(c, $0, strlen($0), 0) }
            close(c); done.fulfill()
        }.start()
        let body = Array("héllo ✓".utf8)
        var r = nk_http_request("POST", "127.0.0.1", UInt16(bigEndian: addr.sin_port), "/actions/clipboard?type=text", 0, nil, nil, nil, 0,
                                body, body.count, "text/plain; charset=utf-8", 3000, nil)
        defer { nk_http_free(&r) }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(box.request.hasPrefix("POST /actions/clipboard?type=text HTTP/1.1"))
        XCTAssertTrue(box.request.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(box.request.hasSuffix("\r\n\r\nhéllo ✓"))
    }

    func testClipboardErrorsSayWhatToDo() {
        if case .host(let m) = StreamClient.clipboardError(.http(404, ""), reading: true) { XCTAssertTrue(m.contains("Apollo")) } else { XCTFail() }
        if case .host(let m) = StreamClient.clipboardError(.http(401, ""), reading: false) { XCTAssertTrue(m.contains("set its clipboard")) } else { XCTFail() }
        if case .host(let m) = StreamClient.clipboardError(.http(403, ""), reading: true) { XCTAssertTrue(m.contains("during a stream")) } else { XCTFail() }
        XCTAssertEqual(StreamClient.clipboardError(.timeout, reading: true), .timeout)
    }
}

final class PresentedControllerTests: XCTestCase {
    func testTheProfileTellsWineWhichControllerToPresent() {
        var p = PadProfiles.Profile(name: "Pad")
        XCTAssertFalse(PadProfiles.compile(p, all: [p]).contains("present"), "as it is by default")
        p.presentAs = .xbox
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.hasSuffix("present xbox\n"))
        // The mapping engine skips the line and still reads the profile.
        let e = text.withCString { pe_create($0, pe_sink()) }
        XCTAssertNotNil(e); if let e { pe_destroy(e) }
        // Inherited from the profile it builds on, and kept with native routing.
        var child = PadProfiles.Profile(name: "Child", buildsOn: [p.id]); child.routingMode = .native
        XCTAssertEqual(PadProfiles.compile(child, all: [p, child]), "nokpad 1\npresent xbox\n")
    }

    func testIdentities() {
        XCTAssertEqual(PresentedController.xbox.vendorID, 0x045E)
        XCTAssertEqual(PresentedController.dualShock4.productID, 0x05C4)
        XCTAssertEqual(PresentedController.switchPro.productID, 0x2009)
        XCTAssertEqual(PresentedController.allCases.filter(\.available), [.xbox, .dualShock4, .switchPro])
    }

    func testOlderProfilesPresentTheControllerAsItIs() throws {
        // A profile saved before this setting existed has no "presentAs" key.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PadProfiles.Profile(name: "Old"))) as! [String: Any]
        json["presentAs"] = nil
        let p = try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(p.presentAs)
        var q = p; q.presentAs = .xbox
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(q)).presentAs, .xbox)
    }
}

final class VBANPacingTests: XCTestCase {
    func testPacedPacketsAndBacklog() {
        var p = VBANPacketizer(streamName: "Mic", sampleRate: 24000, channels: 1)
        p.append([Int16](repeating: 100, count: 256 * 3 + 10))
        XCTAssertEqual(p.backlog, 3)
        XCTAssertNotNil(p.nextPacket()); XCTAssertNotNil(p.nextPacket()); XCTAssertNotNil(p.nextPacket())
        XCTAssertNil(p.nextPacket(), "a partial packet waits")
        XCTAssertEqual(p.frameCounter, 3)
        p.append([Int16](repeating: 1, count: 256 * 20))
        XCTAssertEqual(p.backlog, 5, "older audio dropped past the backlog")
        XCTAssertEqual(VBANPacketizer.peakDB([0, 0]), -120)
        XCTAssertEqual(VBANPacketizer.peakDB([16384]), -6.02, accuracy: 0.01)
    }
}

final class VBANProcessorTests: XCTestCase {
    private func tone(_ freq: Double, amplitude: Float, seconds: Double = 0.5, rate: Double = 48000) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * freq * Double($0) / rate)) }
    }
    private func peak(_ x: [Float], from: Int = 12000) -> Float { x[from...].map(abs).max() ?? 0 }

    func testGain() {
        var s = VBANSettings(); s.gainDB = 6
        var p = VBANProcessor(settings: s, sampleRate: 48000, channels: 1)
        var x = tone(440, amplitude: 0.1); p.process(&x)
        XCTAssertEqual(peak(x), 0.1995, accuracy: 0.005)
    }

    func testGateSilencesQuietAndPassesSpeech() {
        var s = VBANSettings(); s.gate = 0.5          // opens at about −50 dBFS
        var p = VBANProcessor(settings: s, sampleRate: 48000, channels: 1)
        var hiss = tone(440, amplitude: 0.0005); p.process(&hiss)   // about −66 dBFS
        XCTAssertLessThan(peak(hiss), 0.00005, "room noise is shut out")
        var voice = tone(440, amplitude: 0.1); p.process(&voice)
        XCTAssertEqual(peak(voice), 0.1, accuracy: 0.005, "speech passes")
    }

    func testCompressorEvensOutLoudness() {
        var s = VBANSettings(); s.compressor = 1
        var loud = VBANProcessor(settings: s, sampleRate: 48000, channels: 1), quiet = loud
        var a = tone(440, amplitude: 0.9), b = tone(440, amplitude: 0.05)
        loud.process(&a); quiet.process(&b)
        XCTAssertLessThan(peak(a) / peak(b), 0.9 / 0.05 / 2, "the loud/quiet ratio shrinks")
        XCTAssertLessThanOrEqual(peak(a), 0.98)
    }

    func testBassBoostRaisesLowsNotHighs() {
        var s = VBANSettings(); s.bassDB = 12
        var p = VBANProcessor(settings: s, sampleRate: 48000, channels: 1), q = p
        var low = tone(60, amplitude: 0.1), high = tone(4000, amplitude: 0.1)
        p.process(&low); q.process(&high)
        XCTAssertGreaterThan(peak(low), 0.3)
        XCTAssertEqual(peak(high), 0.1, accuracy: 0.02)
    }

    func testLimiterAndMeter() {
        var s = VBANSettings(); s.gainDB = 24
        var p = VBANProcessor(settings: s, sampleRate: 48000, channels: 2)
        var x = tone(440, amplitude: 0.5).flatMap { [$0, $0] }
        p.process(&x)
        XCTAssertLessThanOrEqual(x.map(abs).max()!, 0.98)
        XCTAssertEqual(p.takePeak(), 0.98, accuracy: 0.001)
        XCTAssertEqual(p.takePeak(), 0)
    }

    func testPacketSizeAndOldSettings() throws {
        XCTAssertEqual(VBANPacketizer(streamName: "x", sampleRate: 48000, channels: 1, packetSamples: 128).samplesPerPacket, 128)
        let old = try JSONDecoder().decode(VBANSettings.self, from: Data(#"{"enabled":true,"streamName":"Stream1"}"#.utf8))
        XCTAssertEqual(old.packetSamples, 256); XCTAssertEqual(old.gainDB, 0); XCTAssertFalse(old.pushToTalk)
    }
}

import NokcanduOpus

/// The stream's Opus path: a tone encoded the way the host does (stereo multistream, 5 ms frames) decodes back.
final class StreamOpusTests: XCTestCase {
    func testStereoToneRoundTrips() {
        var err: Int32 = 0
        let mapping: [UInt8] = [0, 1]
        let enc = opus_multistream_encoder_create(48000, 2, 1, 1, mapping, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err)
        XCTAssertEqual(err, OPUS_OK); XCTAssertNotNil(enc)
        let dec = mapping.withUnsafeBufferPointer { nk_opus_create(48000, 2, 1, 1, $0.baseAddress) }
        XCTAssertNotNil(dec)
        var peak: Float = 0, decoded = 0
        for frame in 0..<100 {
            let pcm = (0..<240).flatMap { i -> [Float] in
                let v = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame * 240 + i) / 48000)); return [v, v]
            }
            var packet = [UInt8](repeating: 0, count: 1500)
            let n = opus_multistream_encode_float(enc!, pcm, 240, &packet, 1500)
            XCTAssertGreaterThan(n, 0)
            var out = [Float](repeating: 0, count: 5760 * 2)
            let got = packet.withUnsafeBufferPointer { p in out.withUnsafeMutableBufferPointer { nk_opus_decode(dec!, p.baseAddress, n, $0.baseAddress, 5760) } }
            XCTAssertEqual(got, 240)
            decoded += Int(got)
            if frame > 10 { peak = max(peak, out.prefix(480).map(abs).max()!) }
        }
        XCTAssertEqual(decoded, 24000)
        XCTAssertGreaterThan(peak, 0.3, "the tone comes back")
        opus_multistream_encoder_destroy(enc!); nk_opus_destroy(dec!)
    }
}

final class StreamKeyboardLayoutTests: XCTestCase {
    func testAStreamFollowsTheDefaultLayoutUnlessToldOtherwise() {
        let caps = KeyRemap.Layout(id: "caps", name: "Caps to Control", mappings: [KeyRemap.Mapping(from: 57, to: 59)])
        let wasd = KeyRemap.Layout(id: "wasd", name: "Arrows", mappings: [KeyRemap.Mapping(from: 13, to: 126)])
        var input = StreamProfile.Input()
        XCTAssertEqual(input.keyMappings(layouts: [caps, wasd], defaultLayout: .some(caps)), caps.mappings, "the default games use")
        XCTAssertEqual(input.keyMappings(layouts: [caps, wasd], defaultLayout: .some(nil)), [], "no default: normal keys")
        input.keyboardLayout = "wasd"
        XCTAssertEqual(input.keyMappings(layouts: [caps, wasd], defaultLayout: .some(caps)), wasd.mappings)
        input.keyboardLayout = "none"
        XCTAssertEqual(input.keyMappings(layouts: [caps, wasd], defaultLayout: .some(caps)), [])
        input.keyboardLayout = "deleted"
        XCTAssertEqual(input.keyMappings(layouts: [caps, wasd], defaultLayout: .some(caps)), [], "a removed layout means normal keys")
    }
}

final class StreamDisplaySettingTests: XCTestCase {
    func testWindowSettingsSavedBeforeDisplaysExistedFollowNokcandusDisplay() throws {
        let old = try JSONDecoder().decode(StreamProfile.Window.self, from: Data(#"{"fullScreen":true,"statistics":"basic"}"#.utf8))
        XCTAssertNil(old.display)
        var w = StreamProfile.Window()
        w.display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"; w.displayName = "Studio Display (5120×2880)"
        let back = try JSONDecoder().decode(StreamProfile.Window.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(back, w)
    }
}

final class StickModeTitleTests: XCTestCase {
    func testStickChoicesNameWhichStickGamesSee() {
        XCTAssertEqual(PadProfiles.StickMode.stick.title(forStick: 0), "Left stick")
        XCTAssertEqual(PadProfiles.StickMode.otherStick.title(forStick: 0), "Right stick (swapped)")
        XCTAssertEqual(PadProfiles.StickMode.stick.title(forStick: 1), "Right stick")
        XCTAssertEqual(PadProfiles.StickMode.otherStick.title(forStick: 1), "Left stick (swapped)")
        XCTAssertEqual(PadProfiles.StickMode.mouse.title(forStick: 1), "Mouse")
    }
}

final class ProfileLibraryResilienceTests: XCTestCase {
    private func library(tapOutput: String) throws -> Data {
        var fine = PadProfiles.Profile(id: "a", name: "Fine")
        fine.layers[0][.a] = .as(.key(0))
        var steam = PadProfiles.Profile(id: "b", name: "Steam Controller 2")
        steam.layers[0][.lptap] = PadProfiles.Binding(tap: [.key(7)], hold: [.nothing])
        let text = String(decoding: try JSONEncoder().encode([fine, steam]), as: UTF8.self)
        XCTAssertTrue(text.contains("\"key:7\""))
        return Data(text.replacingOccurrences(of: "\"key:7\"", with: "\"\(tapOutput)\"").utf8)
    }

    /// November 13, 2026: a trackpad tap set to Tap/Hold saved "pad:lptap", which didn't read back, and every
    /// profile disappeared. One unreadable output must not lose the library, and the original is kept.
    func testOneUnreadableOutputKeepsEveryProfileAndTheOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("controller-profiles.json")
        let original = try library(tapOutput: "pad:lptap")
        try original.write(to: file)
        XCTAssertThrowsError(try JSONDecoder().decode([PadProfiles.Profile].self, from: original), "still strict outside the library")

        let list = PadProfiles.profiles(file: file)
        XCTAssertEqual(list.map(\.name), ["Fine", "Steam Controller 2"])
        guard list.count == 2 else { return }
        XCTAssertEqual(list[1].layers[0][.lptap]?.tap, [.nothing])
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("unreadable-backup")), original)

        try PadProfiles.saveProfiles(list, file: file)
        XCTAssertEqual(try JSONDecoder().decode([PadProfiles.Profile].self, from: Data(contentsOf: file)).count, 2, "saved file reads strictly")
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("unreadable-backup")), original, "backup kept")
    }

    func testAnOutputThatWouldNotReadBackIsSavedAsNothing() throws {
        let b = PadProfiles.Binding(tap: [.pad(.lptap)], hold: [.nothing])
        let back = try JSONDecoder().decode(PadProfiles.Binding.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.tap, [.nothing])
    }

    func testDataThatIsNotProfilesStillIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("controller-profiles.json")
        try Data("{not json".utf8).write(to: file)
        XCTAssertThrowsError(try PadProfiles.saveProfiles([], file: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{not json")
    }
}

final class ControllerRumbleTests: XCTestCase {
    func testTheHelpersRequestsParse() throws {
        let r = try XCTUnwrap(ControllerRumble.Request.parse("nokcandu-rumble 1 28de 1102 32768 16384 250 Steam Controller"))
        XCTAssertEqual(r.vendor, 0x28de); XCTAssertEqual(r.product, 0x1102)
        XCTAssertEqual(r.low, 32768 / 65535, accuracy: 1e-9); XCTAssertEqual(r.milliseconds, 250); XCTAssertEqual(r.name, "Steam Controller")
        XCTAssertTrue(ControllerRumble.isOriginalSteamController(vendor: r.vendor, product: r.product))
        XCTAssertNotNil(ControllerRumble.Request.parse("nokcandu-rumble 1 045e 028e 0 0 0 "))
        XCTAssertNil(ControllerRumble.Request.parse("nokcandu-rumble 2 28de 1102 1 1 1 x"))
        XCTAssertNil(ControllerRumble.Request.parse("garbage"))
    }

    func testRumbleRunsForItsTimeAndStopsWhenAsked() throws {
        var s = ControllerRumble.State()
        s.apply(try XCTUnwrap(ControllerRumble.Request.parse("nokcandu-rumble 1 28de 1102 65535 0 250 x")), now: 10)
        XCTAssertEqual(s.strength(at: 10.2), 1); XCTAssertEqual(s.strength(at: 10.3), 0)
        s.apply(try XCTUnwrap(ControllerRumble.Request.parse("nokcandu-rumble 1 28de 1102 0 32768 0 x")), now: 20)
        XCTAssertEqual(s.strength(at: 24), 32768 / 65535, accuracy: 1e-9, "no end given: runs")
        XCTAssertEqual(s.strength(at: 20 + ControllerRumble.State.longest + 0.01), 0, "but never forever")
        s.apply(try XCTUnwrap(ControllerRumble.Request.parse("nokcandu-rumble 1 28de 1102 0 0 0 x")), now: 21)
        XCTAssertEqual(s.strength(at: 21), 0, "a stop stops at once")
    }
}

final class EverywhereProfileMapTests: XCTestCase {
    /// November 13, 2026: with a profile used everywhere, Wine's controller driver switched off, so gyro-as-stick and
    /// remapped buttons never reached Windows games. The profile is now compiled for the driver.
    func testTheEverywhereProfileIsCompiledForWinesDriverAndRemovedWhenStopped() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".map")
        defer { try? FileManager.default.removeItem(at: file) }
        var p = PadProfiles.Profile(id: "pad", name: "Steam Controller xbox")
        p.layers[0][.lt] = PadProfiles.Binding(press: [.trigger(right: true), .gyroOn])
        XCTAssertTrue(PadProfiles.writeEverywhereMap(id: "pad", all: [p], to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), PadProfiles.compile(p, all: [p]))
        XCTAssertFalse(PadProfiles.writeEverywhereMap(id: nil, all: [p], to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(PadProfiles.writeEverywhereMap(id: "deleted", all: [p], to: file), "a removed profile leaves no map")
    }
}

final class ControllerSummaryTests: XCTestCase {
    func testTheReportedSetupReadsAsOneSentence() {
        let p = ControllerSummary.Profile(name: "Steam Controller xbox", presentAs: .xbox, gyro: .rightStick, gyroByButton: true, changed: 1)
        XCTAssertEqual(ControllerSummary.line(controllers: ["Steam Controller"], steamController: true, mode: .xbox, steam: true,
                                              profile: p, everywhere: true, profilesOff: false),
                       "Steam Controller → Xbox controller · profile “Steam Controller xbox” (used everywhere) · gyro as the right stick (a button turns it on) · rumble on the trackpads")
    }

    func testWhatGamesSeeFollowsTheSettingThatDecidesIt() {
        let ds4 = ControllerSummary.Profile(name: "P", presentAs: .dualShock4)
        XCTAssertEqual(ControllerSummary.seenAs(mode: .native, steam: false, profile: ds4), "DualShock 4", "the profile's emulated controller wins")
        XCTAssertEqual(ControllerSummary.seenAs(mode: .hidden, steam: false, profile: ds4), "no controller (keys and mouse only)", "Not at all still wins")
        XCTAssertEqual(ControllerSummary.seenAs(mode: .automatic, steam: false, profile: ControllerSummary.Profile(name: "P")), "Xbox controller", "a profile needs Wine's conversion")
        XCTAssertEqual(ControllerSummary.seenAs(mode: .automatic, steam: true, profile: nil), "itself, for Steam Input")
        XCTAssertTrue(ControllerSummary.line(controllers: [], steamController: false, mode: .xbox, steam: false, profile: ds4, everywhere: false, profilesOff: true)
            .hasPrefix("No controller connected — games will see Xbox controller · controller profiles are off"))
    }

    func testGyroTurnedOnByAButtonIsNoticed() {
        var p = PadProfiles.Profile(id: "a", name: "A")
        var g = PadProfiles.Gyro(); g.output = .rightStick; g.startsOn = false; p.gyro = g
        p.layers[0][.lt] = PadProfiles.Binding(press: [.trigger(right: true), .gyroOn])
        let s = ControllerSummary.Profile(p, all: [p])
        XCTAssertTrue(s.gyroByButton); XCTAssertEqual(s.gyro, .rightStick)
    }
}
