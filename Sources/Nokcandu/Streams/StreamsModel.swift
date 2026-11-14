// SPDX-License-Identifier: GPL-3.0-only
// The Streams tab's state: saved hosts and stream profiles, hosts found on the network, pairing, and the running stream.
import AppKit
import Network
import NokcanduCore

@MainActor final class StreamsModel: ObservableObject {
    static let shared = StreamsModel()

    @Published private(set) var library = StreamLibrary.load()
    @Published var selectedHost: String?
    @Published var selectedProfile: String?
    @Published private(set) var status: [String: HostStatus] = [:]
    @Published private(set) var discovered: [Discovered] = []
    @Published var pairing: Pairing?
    @Published var showConnect = false
    @Published private(set) var running: Running?
    @Published var lastError: String?
    @Published private(set) var art: [String: NSImage] = [:]

    struct HostStatus: Equatable {
        var online = false
        var checking = false
        var currentGame = 0
        var address: String?
        var busy = false
        var error: String?
        /// The host refused this Mac's certificate: pair again.
        var needsPairing = false
    }
    struct Discovered: Identifiable, Equatable {
        var id: String { address }
        var name: String
        var address: String
    }
    struct Pairing: Equatable {
        var address: String
        var name: String
        var pin: String
        var stage: Stage = .waiting
        enum Stage: Equatable { case waiting, failed(String), done }
    }
    struct Running: Equatable {
        var hostID: String
        var profileID: String
        var connected = false
    }

    private var identity: StreamIdentity?
    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []
    private var window: StreamWindowController?
    private var pairClient: StreamClient?
    private var refreshTimer: Timer?

    private init() {
        StreamClient.log = { StreamLog.shared.add($0) }
        selectedHost = library.hosts.first?.id
        selectedProfile = selectedHost.flatMap { library.profiles(for: $0).first?.id }
    }

    func loadIdentity() throws -> StreamIdentity {
        if let identity { return identity }
        let id = try StreamIdentity.loadOrCreate()
        identity = id
        return id
    }

    // MARK: Saving

    func update(_ change: (inout StreamLibrary) -> Void) {
        var lib = library
        change(&lib)
        guard lib != library else { return }
        library = lib
        do { try lib.save() } catch { lastError = "Couldn't save your streams: \(error.localizedDescription)" }
    }

    func host(_ id: String?) -> StreamHost? { id.flatMap { i in library.hosts.first { $0.id == i } } }
    func profile(_ id: String?) -> StreamProfile? { id.flatMap { i in library.profiles.first { $0.id == i } } }

    func setProfile(_ p: StreamProfile) {
        update { lib in if let i = lib.profiles.firstIndex(where: { $0.id == p.id }) { lib.profiles[i] = p } }
        // Changes that can apply during the stream do (the window decides which).
        if running?.profileID == p.id { window?.apply(p) }
    }

    func addProfile(to hostID: String, copying source: StreamProfile? = nil) {
        var p = source ?? StreamProfile(hostID: hostID, name: "Stream")
        p.id = UUID().uuidString; p.hostID = hostID
        let names = Set(library.profiles(for: hostID).map(\.name))
        if source != nil { p.name = source!.name + " copy" }
        else if library.profiles(for: hostID).isEmpty { p.name = "Home" }
        else if !names.contains("Away") { p.name = "Away"; p.route = .remote; p.video.bitrateKbps = 20000 }
        var n = 2, base = p.name
        while names.contains(p.name) { p.name = "\(base) \(n)"; n += 1 }
        if p.appID == nil, let h = host(hostID) {
            let app = h.apps.first { $0.name.localizedCaseInsensitiveContains("desktop") } ?? h.apps.first
            p.appID = app?.id; p.appName = app?.name
        }
        base = p.name
        update { $0.profiles.append(p) }
        selectedHost = hostID; selectedProfile = p.id
    }

    func removeProfile(_ id: String) {
        update { $0.profiles.removeAll { $0.id == id } }
        if selectedProfile == id { selectedProfile = selectedHost.flatMap { library.profiles(for: $0).first?.id } }
    }

    func renameHost(_ id: String, _ name: String) {
        update { lib in if let i = lib.hosts.firstIndex(where: { $0.id == id }) { lib.hosts[i].name = name } }
    }

    /// Forgets the host and its stream profiles (and asks the host to forget this Mac).
    func removeHost(_ id: String) {
        if let h = host(id), let identity, let address = status[id]?.address ?? h.candidates().first {
            let client = StreamClient(address: address, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity,
                                      serverCertificate: h.serverCertificate.flatMap { Data(base64Encoded: $0) })
            DispatchQueue.global().async { client.unpair() }
        }
        update { $0.removeHost(id) }
        status[id] = nil
        if selectedHost == id { selectedHost = library.hosts.first?.id; selectedProfile = selectedHost.flatMap { library.profiles(for: $0).first?.id } }
    }

    // MARK: Checking hosts

    /// Asks every saved host whether it's on, and refreshes its apps. Repeats every 20 seconds while the tab is shown.
    func startWatching() {
        refresh()
        startDiscovery()
        guard refreshTimer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { StreamsModel.shared.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }
    func stopWatching() {
        refreshTimer?.invalidate(); refreshTimer = nil
        browser?.cancel(); browser = nil
    }

    func refresh() {
        // Like Moonlight, don't poll hosts during a stream: the host is busy, and its secure port is the same one
        // that has stopped answering after streams (docs/streams.md).
        guard running == nil, let identity = try? loadIdentity() else { return }
        for h in library.hosts { check(h, identity: identity) }
    }

    private func check(_ h: StreamHost, identity: StreamIdentity) {
        guard status[h.id]?.checking != true else { return }
        status[h.id, default: HostStatus()].checking = true
        let candidates = h.candidates()
        let cert = h.serverCertificate.flatMap { Data(base64Encoded: $0) }
        let fetchApps = h.isPaired
        DispatchQueue.global(qos: .utility).async {
            var result: (StreamServerInfo, String, [StreamApp]?)?
            var lastError: String?
            var recovered: Data?
            for a in candidates {
                let client = StreamClient(address: a, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity, serverCertificate: cert)
                do {
                    let info = try client.serverInfo(timeout: 3)
                    var apps = fetchApps && info.pairStatusKnown ? try? client.apps() : nil
                    // Saved pairing missing here but the host still knows this Mac: restore it without a PIN.
                    if cert == nil, let c = client.recoverPairing() {
                        recovered = c
                        client.serverCertificate = c
                        apps = try? client.apps()
                    }
                    result = (info, a, apps)
                    break
                } catch {
                    lastError = (error as? LocalizedError)?.errorDescription
                    StreamLog.shared.add("Check \(h.name) at \(a): \(lastError ?? "\(error)")")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = StreamsModel.shared
                    var s = m.status[h.id] ?? HostStatus()
                    s.checking = false
                    if let (info, address, apps) = result {
                        s.online = true; s.address = address; s.currentGame = info.currentGame; s.busy = info.busy; s.error = nil
                        s.needsPairing = info.certificateRejected
                        m.update { lib in
                            let id = lib.merge(info, reachedAt: address, placeholder: h.id)
                            if let i = lib.hosts.firstIndex(where: { $0.id == id }) {
                                if let apps, !apps.isEmpty { lib.hosts[i].apps = apps }
                                if let recovered { lib.hosts[i].serverCertificate = recovered.base64EncodedString() }
                            }
                        }
                        if h.id != info.uniqueID, !info.uniqueID.isEmpty {
                            m.status[h.id] = nil
                            if m.selectedHost == h.id { m.selectedHost = info.uniqueID }
                            m.status[info.uniqueID] = s
                        } else { m.status[h.id] = s }
                    } else {
                        s.online = false; s.error = lastError
                        m.status[h.id] = s
                    }
                }
            }
        }
    }

    /// The app's box art, fetched once per host and app.
    func artwork(host h: StreamHost, app: Int) -> NSImage? {
        let key = "\(h.id)/\(app)"
        if let a = art[key] { return a }
        guard h.isPaired, let identity, let address = status[h.id]?.address, status[h.id]?.online == true else { return nil }
        art[key] = NSImage()       // asked for; a real image replaces it
        let client = StreamClient(address: address, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity,
                                  serverCertificate: h.serverCertificate.flatMap { Data(base64Encoded: $0) })
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? client.appArt(app), let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.art[key] = image } }
        }
        return nil
    }

    // MARK: Finding hosts on this network

    func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.resolve(Array(results)) } }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    private func resolve(_ results: [NWBrowser.Result]) {
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            if discovered.contains(where: { $0.name == name }) { continue }
            // Resolve the service to an address by connecting to it.
            let c = NWConnection(to: r.endpoint, using: .tcp)
            resolving.append(c)
            c.stateUpdateHandler = { state in
                guard case .ready = state, let remote = c.currentPath?.remoteEndpoint, case .hostPort(let host, _) = remote else {
                    if case .failed = state { c.cancel() }
                    return
                }
                var address: String
                switch host {
                case .ipv4(let a): address = "\(a)"
                case .ipv6(let a): address = "\(a)"
                case .name(let n, _): address = n
                @unknown default: address = "\(host)"
                }
                if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
                c.cancel()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let m = StreamsModel.shared
                        m.resolving.removeAll { $0 === c }
                        if !m.discovered.contains(where: { $0.address == address }) {
                            m.discovered.append(Discovered(name: name, address: address))
                        }
                    }
                }
            }
            c.start(queue: .global(qos: .utility))
        }
    }

    /// Found on the network and not saved yet.
    var newlyDiscovered: [Discovered] {
        discovered.filter { d in !library.hosts.contains { $0.localAddress == d.address || $0.manualAddress == d.address || $0.name == d.name } }
    }

    // MARK: Pairing

    /// Pairs again with a saved host (its pairing was lost or reset).
    func pairAgain(_ h: StreamHost) {
        showConnect = true
        connect(to: status[h.id]?.address ?? h.candidates().first ?? "", name: h.name)
    }

    /// Adds the host at an address and pairs with it: shows a PIN to type on the host.
    func connect(to address: String, name: String? = nil) {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, let identity = try? loadIdentity() else { lastError = "Couldn't make this Mac's certificate for pairing."; return }
        let pin = StreamClient.newPIN()
        pairing = Pairing(address: a, name: name ?? a, pin: pin)
        let client = StreamClient(address: a, identity: identity)
        pairClient = client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try client.serverInfo(timeout: 5)
                DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.pairing?.name = info.hostname.isEmpty ? a : info.hostname } }
                // Already paired on the host (this Mac's certificate is known): no PIN needed.
                if let known = client.recoverPairing() {
                    client.serverCertificate = known
                    let apps = (try? client.apps()) ?? []
                    DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.paired(info: info, address: a, certificate: known, apps: apps) } }
                    return
                }
                let cert = try client.pair(pin: pin)
                let refreshed = (try? client.serverInfo(timeout: 5)) ?? info
                let apps = (try? client.apps()) ?? []
                DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.paired(info: refreshed, address: a, certificate: cert, apps: apps) } }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                StreamLog.shared.add("Pairing with \(a): \(message)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard error as? StreamError != .cancelled else { return }
                        StreamsModel.shared.pairing?.stage = .failed(message)
                    }
                }
            }
        }
    }

    func cancelPairing() {
        pairClient?.cancel(); pairClient = nil
        pairing = nil
    }

    private func paired(info: StreamServerInfo, address: String, certificate: Data?, apps: [StreamApp] = []) {
        pairClient = nil
        var id = ""
        update { lib in
            id = lib.merge(info, reachedAt: address)
            if let i = lib.hosts.firstIndex(where: { $0.id == id }) {
                if let certificate { lib.hosts[i].serverCertificate = certificate.base64EncodedString() }
                if !apps.isEmpty { lib.hosts[i].apps = apps }
            }
            _ = lib.addStarterProfile(for: id)
        }
        status[id] = HostStatus(online: true, currentGame: info.currentGame, address: address)
        selectedHost = id
        selectedProfile = library.profiles(for: id).first?.id
        pairing?.stage = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.pairing?.stage == .done { self?.pairing = nil; self?.showConnect = false }
        }
        status[id]?.needsPairing = false
    }

    // MARK: Wake-on-LAN

    func wake(_ h: StreamHost) {
        guard let mac = h.macAddress else { return }
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }
        let targets = ["255.255.255.255"] + h.candidates().map { StreamAddress.split($0).host }
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            // Moonlight's ports: the usual WoL ports and GameStream's own.
            for target in targets {
                for port in [9, 7, 47998, 47999, 48000, 48002, 48010] as [UInt16] {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                    _ = withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.refresh() }
    }

    // MARK: Streaming

    func stream(_ p: StreamProfile) {
        guard running == nil, let h = host(p.hostID) else { return }
        guard h.isPaired else { lastError = "Pair with \(h.name) first."; return }
        guard let identity = try? loadIdentity() else { lastError = "Couldn't load this Mac's certificate."; return }
        let address: String
        if case .manual(let a) = p.route { address = a }
        else if let a = status[h.id]?.address, status[h.id]?.online == true, p.route == .automatic || (p.route == .local) == StreamAddress.isPrivate(a) { address = a }
        else if let a = h.candidates(p.route).first { address = a }
        else { lastError = "\(h.name) has no address to stream from. Connect to it again."; return }
        let w = StreamWindowController(host: h, profile: p, address: address, identity: identity)
        w.onEnd = { [weak self] error in
            self?.running = nil
            self?.window = nil
            if let error { self?.lastError = error }
            self?.refresh()
        }
        window = w
        running = Running(hostID: h.id, profileID: p.id)
        w.begin()
    }

    func showStream() { window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil) }
    func toggleMicMute() { window?.toggleMicMute() }
    /// The VBAN microphone's level now (0…1), or nil when it isn't sending.
    var micLevel: Float? { window?.micLevel }
    func sendClipboard() { window?.sendClipboard(auto: false) }
    func fetchClipboard() { window?.fetchClipboard(auto: false) }

    /// Frees the pointer from a captured stream, or captures it again.
    func togglePointer() {
        guard let w = window else { return }
        if w.state.captured { w.releaseMouse() } else { showStream(); w.captureMouse() }
    }
    var streamName: String? { running.flatMap { r in profile(r.profileID).map { "\($0.name) — \(host(r.hostID)?.name ?? "")" } } }
    func endStream(quitApp: Bool) { window?.endStream(quitApp: quitApp) }

    /// Nokcandu is quitting: end a running stream properly (the host is told), waiting briefly for it. A stream that
    /// just vanishes (Nokcandu killed mid-stream) has twice left Sunshine's secure port stuck until it was restarted.
    func endStreamForQuit() {
        guard running != nil, let c = StreamConnection.current else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { c.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
        StreamLog.shared.add("Stream ended because Nokcandu quit")
    }

    /// Quits whatever app is running on the host.
    func quitApp(on h: StreamHost) {
        guard let identity = try? loadIdentity(), let address = status[h.id]?.address else { return }
        let client = StreamClient(address: address, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity,
                                  serverCertificate: h.serverCertificate.flatMap { Data(base64Encoded: $0) })
        DispatchQueue.global().async {
            do { try client.quit() } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.lastError = message } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { StreamsModel.shared.refresh() } }
        }
    }
}
