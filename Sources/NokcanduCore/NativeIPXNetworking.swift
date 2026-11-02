import Foundation
import SystemConfiguration

/// Optional original-IPX transport. The base component supplies Winsock 1 and legacy DirectPlay;
/// this component supplies native capture and the Microsoft-compatible discovery provider.
public enum NativeIPXNetworking {
    static let revision = 2
    static let helperName = "native-ipx-access"
    static let flag = "NOKCANDU_NATIVE_IPX"
    static let interfaceFlag = "NOKCANDU_NATIVE_IPX_INTERFACE"
    static let providerSHA = "0725598871b2f1f65ccd0235683873346c8024a38dead045bce20526af65654d"
    static let moduleFiles = ["i386-windows/wpcap.dll", "x86_64-windows/wpcap.dll", "x86_64-unix/wpcap.so"]
    nonisolated(unsafe) static var resourceForTesting: URL?
    static var resource: URL? {
        if let resourceForTesting { return resourceForTesting }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Nokcandu.app/Contents/Resources/native-ipx")
        return [NokPaths.bundledResource("native-ipx"), development].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("11.0/SHA256SUMS").path) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(helperName).path)
        }
    }
    static func module(for g: InstalledGame) -> URL? {
        guard let version = WindowedPresentation.engineVersion(host: g.contents), version.major == 11, version.minor == 0,
              let root = resource else { return nil }
        let module = root.appendingPathComponent("11.0")
        return moduleFiles.allSatisfy { FileManager.default.fileExists(atPath: module.appendingPathComponent($0).path) } ? module : nil
    }
    public static func supports(_ g: InstalledGame) -> Bool { IPXNetworking.supports(g) && module(for: g) != nil }
    static func directory(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("native-ipx") }

    static func plannedFiles(for g: InstalledGame) throws -> [URL: Data] {
        guard supports(g), let module = module(for: g), let root = resource,
              let exe = CompatibilityFixes.managedProgram(g) else { throw NokError("Native IPX requires a private 32-bit game with the supported Wine 11 engine and Nokcandu's packet module.") }
        let game = exe.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let base = CompatibilityFixes.journal(.ipxNetworking, g)
        let native = CompatibilityFixes.journal(.nativeIPXNetworking, g)
        let upgrading = CompatibilityFixes.isInstalled(.nativeIPXNetworking, for: g)
        if upgrading { try native.validateForUndo() } else { try base.validateForUndo() }
        let provider = g.prefix.appendingPathComponent("drive_c/windows/syswow64/dpwsockx.dll")
        guard try Hashing.sha256(file: provider) == providerSHA else { throw NokError("The private DirectPlay provider changed. It was left untouched.") }
        let target = game.appendingPathComponent("dpwsockx.dll")
        let ownership = upgrading ? native : base
        guard let owned = ownership.entries.last(where: { $0.path == target.path })?.shaAfter,
              (try? Hashing.sha256(file: target)) == owned else { throw NokError("The IPX provider beside the game is not the unchanged managed component.") }
        var files: [URL: Data] = [target: try Data(contentsOf: provider)]
        let manifest = try String(contentsOf: module.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        for member in moduleFiles {
            let source = module.appendingPathComponent(member), data = try Data(contentsOf: source)
            let sha = Hashing.sha256(data: data)
            guard manifest.split(separator: "\n").contains(where: { $0.split(whereSeparator: \.isWhitespace).map(String.init) == [sha, member] }) else {
                throw NokError("Nokcandu's packet module did not match its bundled fingerprint.")
            }
            if member.hasPrefix("i386") {
                guard PEFile.parse(data)?.is64 == false else { throw NokError("The packet module has the wrong architecture.") }
                files[game.appendingPathComponent("wpcap.dll")] = data
            }
            files[directory(g).appendingPathComponent("wine/" + member)] = data
        }
        files[directory(g).appendingPathComponent(helperName)] = try Data(contentsOf: root.appendingPathComponent(helperName))
        for (destination, data) in files {
            guard destination.resolvingSymlinksInPath().standardizedFileURL == destination.standardizedFileURL else { throw NokError("A native IPX destination is a link. It was left untouched.") }
            if destination != target, FileManager.default.fileExists(atPath: destination.path), (try? Data(contentsOf: destination)) != data {
                let owned = native.entries.last(where: { $0.path == destination.path })?.shaAfter
                guard upgrading, let owned, (try? Hashing.sha256(file: destination)) == owned else {
                    throw NokError("\(destination.lastPathComponent) already exists and differs. It was left untouched.")
                }
            }
        }
        return files
    }

    struct Value: Codable, Equatable {
        var type: String
        var data: String
        static func dword(_ value: Int) -> Value { Value(type: "REG_DWORD", data: String(value)) }
        static func binary(_ bytes: String) -> Value { Value(type: "REG_BINARY", data: bytes.lowercased()) }
    }
    struct RegistryChange: Codable, Equatable {
        var key: String
        var name: String
        var previous: Value?
        var applied: Value
    }
    static let registryRoot = "HKCU\\Software\\IPXWrapper"
    static func command(_ args: [String], for g: InstalledGame) throws -> ShellResult {
        try Shell.run(g.support.appendingPathComponent("wine/bin/wine").path, ["reg"] + args,
                                 env: WineTools.environment(contents: g.contents), timeout: 30)
    }
    static func read(_ key: String, _ name: String, for g: InstalledGame) throws -> Value? {
        let result = try command(["query", key, "/v", name], for: g)
        if result.status == 1, result.combined.lowercased().contains("unable to find") { return nil }
        guard result.ok else { throw NokError("Couldn't read the game's IPX settings.") }
        return try parseValue(result.stdout, name: name)
    }
    static func parseValue(_ output: String, name: String) throws -> Value {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[0].caseInsensitiveCompare(name) == .orderedSame else { continue }
            if fields[1] == "REG_DWORD" {
                let raw = fields[2].lowercased(), number = raw.hasPrefix("0x") ? UInt32(raw.dropFirst(2), radix: 16) : UInt32(raw)
                if let number { return Value(type: "REG_DWORD", data: String(number)) }
            } else if fields[1] == "REG_BINARY" {
                let data = fields.dropFirst(2).joined().lowercased()
                if !data.isEmpty, data.count % 2 == 0, data.allSatisfy(\.isHexDigit) { return .binary(data) }
            }
            throw NokError("An IPX setting has an unexpected format. It was left untouched.")
        }
        throw NokError("The IPX setting couldn't be read safely.")
    }
    static func write(_ value: Value?, key: String, name: String, for g: InstalledGame) throws {
        let args = value.map { ["add", key, "/v", name, "/t", $0.type, "/d", $0.data, "/f"] } ?? ["delete", key, "/v", name, "/f"]
        let result = try command(args, for: g)
        guard result.ok || (value == nil && result.status == 1) else { throw NokError("Couldn't update the game's IPX settings.") }
    }
    struct Adapter: Equatable { var name: String; var mac: String; var hasAddress: Bool }
    static func adapters(_ text: String) -> [Adapter] {
        var result: [Adapter] = []
        for line in text.components(separatedBy: .newlines) {
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]); result.append(Adapter(name: name, mac: "", hasAddress: false))
            } else if !result.isEmpty {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "ether", fields.count > 1 {
                    let mac = String(fields[1]).uppercased()
                    if mac.range(of: #"^([0-9A-F]{2}:){5}[0-9A-F]{2}$"#, options: .regularExpression) != nil { result[result.count - 1].mac = mac }
                }
                if fields.first == "inet", fields.count > 1, fields[1] != "0.0.0.0" { result[result.count - 1].hasAddress = true }
            }
        }
        return result.filter { !$0.mac.isEmpty }
    }
    // macOS can redact ifconfig's MAC to 02:00:00:00:00:00 when launched by
    // Foundation. Query the same Wine API used by the capture module instead.
    static func wineAdapters(_ text: String) -> [Adapter] {
        text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
            guard fields.count == 4,
                  fields[0].range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil,
                  fields[2].range(of: #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil,
                  fields[2].uppercased() != "02:00:00:00:00:00",
                  fields[2] != "00:00:00:00:00:00" else { return nil }
            return Adapter(name: fields[0], mac: fields[2].uppercased(), hasAddress: fields[3] != "0.0.0.0" && !fields[3].isEmpty)
        }
    }
    static func gameAdapters(_ g: InstalledGame) throws -> [Adapter] {
        guard let helper = module(for: g)?.appendingPathComponent("adapter-info.exe"),
              let manifest = try? String(contentsOf: helper.deletingLastPathComponent().appendingPathComponent("SHA256SUMS"), encoding: .utf8),
              let sha = try? Hashing.sha256(file: helper),
              manifest.split(separator: "\n").contains(where: { $0.split(whereSeparator: \.isWhitespace).map(String.init) == [sha, "adapter-info.exe"] }) else {
            throw NokError("The bundled IPX adapter reader is missing or changed. Update Nokcandu before choosing a LAN connection.")
        }
        let result = try Shell.run(g.support.appendingPathComponent("wine/bin/wine").path, [helper.path], env: WineTools.environment(contents: g.contents), timeout: 30)
        guard result.ok else { throw NokError("Couldn't read the game's LAN adapter identities. Existing settings were preserved.") }
        return wineAdapters(result.stdout)
    }
    /// Correct only the known managed redacted-MAC defect, while closed. Other
    /// explicit adapter choices and registry edits remain untouched.
    static func refreshAdapter(_ game: InstalledGame) {
        let g = CompatibilityFixes.fresh(game)
        guard let state = CompatibilityFixes.state(.nativeIPXNetworking, g),
              let changes = state.registryChanges,
              changes.contains(where: { $0.key == registryRoot && $0.name == "primary" && $0.applied == .binary("020000000000") }),
              let name = g.custom?.environment?[interfaceFlag],
              (try? CompatibilityFixes.requireClosed(g)) != nil,
              (try? CompatibilityFixes.journal(.nativeIPXNetworking, g).validateForUndo()) != nil,
              changes.allSatisfy({ (try? read($0.key, $0.name, for: g)) == $0.applied }) else { return }
        try? setAdapter(name, for: g)
    }
    struct RegistryPlan { var changes: [RegistryChange]; var interface: String }
    static func registryPlan(for g: InstalledGame) throws -> RegistryPlan {
        let interfaces = try gameAdapters(g)
        let route = try Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 10)
        let preferred = route.stdout.components(separatedBy: .newlines).first { $0.contains("interface:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        let previousPrimary = try read(registryRoot, "primary", for: g)
        let previousMAC = previousPrimary?.type == "REG_BINARY" ? previousPrimary?.data : nil
        guard let primary = interfaces.first(where: { $0.name.hasPrefix("en") && $0.hasAddress && $0.mac.replacingOccurrences(of: ":", with: "").lowercased() == previousMAC }) ?? interfaces.first(where: { $0.name == preferred && $0.name.hasPrefix("en") && $0.hasAddress }) ?? interfaces.first(where: { $0.name.hasPrefix("en") && $0.hasAddress }) else {
            throw NokError("Connect this Mac to your LAN before enabling native IPX.")
        }
        let previousFrame = try read(registryRoot, "frame_type", for: g)
        let frame = previousFrame.flatMap { Int($0.data) }.flatMap { (1...3).contains($0) ? $0 : nil } ?? 3
        var requested: [(String, String, Value)] = [(registryRoot, "use_pcap", .dword(1)), (registryRoot, "frame_type", .dword(frame)),
            (registryRoot, "primary", .binary(primary.mac.replacingOccurrences(of: ":", with: "")))]
        let key = registryRoot + "\\" + primary.mac
        requested.append((key, "enabled", .dword(1)))
        requested.append((key, "net", .binary("00000000")))
        var changes: [RegistryChange] = []
        for (key, name, value) in requested { changes.append(RegistryChange(key: key, name: name, previous: try read(key, name, for: g), applied: value)) }
        return RegistryPlan(changes: changes, interface: primary.name)
    }
    static func validate(_ changes: [RegistryChange], for g: InstalledGame) throws {
        for change in changes {
            let current = try read(change.key, change.name, for: g)
            guard current == change.applied || current == change.previous else { throw NokError("IPX network settings changed after installation. They were preserved; restore them before Undo.") }
        }
    }
    static func apply(_ changes: [RegistryChange], for g: InstalledGame) throws {
        for change in changes { try write(change.applied, key: change.key, name: change.name, for: g) }
    }
    static func restore(_ changes: [RegistryChange], for g: InstalledGame) throws {
        try validate(changes, for: g)
        for change in changes.reversed() { try write(change.previous, key: change.key, name: change.name, for: g) }
    }
    public static func frame(for g: InstalledGame) -> Int? {
        guard CompatibilityFixes.isInstalled(.nativeIPXNetworking, for: g), let value = try? read(registryRoot, "frame_type", for: g),
              let frame = Int(value.data), (1...3).contains(frame) else { return nil }
        return frame
    }
    public static func setFrame(_ frame: Int, for game: InstalledGame) throws {
        let g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.requireClosed(g)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        guard (1...3).contains(frame), var state = CompatibilityFixes.state(.nativeIPXNetworking, g),
              let index = state.registryChanges?.firstIndex(where: { $0.key == registryRoot && $0.name == "frame_type" }) else { throw NokError("Install Native IPX before choosing its frame type.") }
        let before = try read(registryRoot, "frame_type", for: g)
        state.registryChanges?[index].applied = .dword(frame)
        // The person explicitly selected this frame (or applied a previewed profile).
        // Keep the original pre-component value for component Undo.
        let marker = CompatibilityFixes.marker(.nativeIPXNetworking, g)
        let previousRecord = try Data(contentsOf: marker)
        try JSONEncoder().encode(state).write(to: marker, options: .atomic)
        do { try write(.dword(frame), key: registryRoot, name: "frame_type", for: g) }
        catch {
            try? write(before, key: registryRoot, name: "frame_type", for: g)
            try? previousRecord.write(to: marker, options: .atomic)
            throw error
        }
    }
    public struct NetworkAdapter: Identifiable {
        public var id: String
        public var title: String
    }
    public static func availableAdapters() -> [NetworkAdapter] {
        guard let listing = try? Shell.run("/sbin/ifconfig", ["-a"], timeout: 10) else { return [] }
        let system = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return adapters(listing.stdout).filter { $0.name.hasPrefix("en") && $0.hasAddress }.map { adapter in
            let interface = system.first { (SCNetworkInterfaceGetBSDName($0) as String?) == adapter.name }
            let label = interface.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? "LAN connection"
            return NetworkAdapter(id: adapter.name, title: label + " (" + adapter.name + ")")
        }
    }
    public static func setAdapter(_ name: String, for game: InstalledGame) throws {
        let g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.requireClosed(g)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        guard var config = g.custom, var state = CompatibilityFixes.state(.nativeIPXNetworking, g),
              let launcher = g.launcherURL, let fingerprint = config.launcherSHA,
              (try? Hashing.sha256(file: launcher)) == fingerprint else { throw NokError("The launcher changed or Native IPX is not installed. Your setup was preserved.") }
        guard let adapter = try gameAdapters(g).first(where: { $0.name == name && $0.name.hasPrefix("en") && $0.hasAddress }) else { throw NokError("Connect the selected adapter to your LAN first.") }
        let key = registryRoot + "\\" + adapter.mac
        let desired: [(String, String, Value)] = [(registryRoot, "primary", .binary(adapter.mac.replacingOccurrences(of: ":", with: ""))), (key, "enabled", .dword(1)), (key, "net", .binary("00000000"))]
        var rollback: [RegistryChange] = []
        for (path, valueName, value) in desired {
            let current = try read(path, valueName, for: g)
            let change = RegistryChange(key: path, name: valueName, previous: current, applied: value)
            rollback.append(change)
            if let index = state.registryChanges?.firstIndex(where: { $0.key == path && $0.name == valueName }) {
                state.registryChanges?[index].applied = value
            } else {
                if state.registryChanges == nil { state.registryChanges = [] }; state.registryChanges?.append(change)
            }
        }
        let record = CompatibilityFixes.marker(.nativeIPXNetworking, g), previousRecord = try Data(contentsOf: record), previousConfig = config
        if state.appliedEnvironment == nil { state.appliedEnvironment = [:] }
        state.appliedEnvironment?[interfaceFlag] = name
        if config.environment == nil { config.environment = [:] }; config.environment?[interfaceFlag] = name
        try JSONEncoder().encode(state).write(to: record, options: .atomic)
        do {
            try apply(rollback, for: g)
            try CustomGames.save(config, to: g)
        } catch {
            try? restore(rollback, for: g)
            try? CustomGames.save(previousConfig, to: CompatibilityFixes.fresh(g))
            try? previousRecord.write(to: record, options: .atomic)
            throw error
        }
    }
    static func addEnvironment(contents: URL, to env: inout [String: String]) {
        guard let settings = CustomGameConfig.load(contents: contents), settings.environment?[flag] == "1" else { return }
        env[interfaceFlag] = settings.environment?[interfaceFlag]
        let root = contents.appendingPathComponent("SharedSupport/nokcandu/native-ipx/wine").path
        env["WINEDLLPATH"] = root + (env["WINEDLLPATH"].map { ":" + $0 } ?? "")
        var rules = CompatibilityFixes.overrides(env["WINEDLLOVERRIDES"])
        rules["wpcap"] = "b"
        env["WINEDLLOVERRIDES"] = rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }
    static let launcherExports = #"export WINEDLLPATH="$SUPPORT/nokcandu/native-ipx/wine${WINEDLLPATH:+:$WINEDLLPATH}""# + "\n"

    public static func needsUpdate(_ g: InstalledGame) -> Bool {
        guard let state = CompatibilityFixes.state(.nativeIPXNetworking, g) else { return false }
        guard state.nativeIPXRevision == revision,
              let source = resource?.appendingPathComponent(helperName), let expected = try? Hashing.sha256(file: source),
              let owned = CompatibilityFixes.journal(.nativeIPXNetworking, g).entries.last(where: { $0.path == directory(g).appendingPathComponent(helperName).path })?.shaAfter else { return true }
        return expected != owned
    }
    /// Refresh only a verified owned helper while closed. This also safely migrates
    /// the initial timer-based diagnostic installs, preserving their registry Undo.
    static func refreshHelper(_ game: InstalledGame) {
        let g = CompatibilityFixes.fresh(game)
        guard var state = CompatibilityFixes.state(.nativeIPXNetworking, g), needsUpdate(g),
              (try? CompatibilityFixes.requireClosed(g)) != nil, let config = g.custom,
              let launcher = g.launcherURL, let sha = config.launcherSHA,
              (try? Hashing.sha256(file: launcher)) == sha,
              let source = resource?.appendingPathComponent(helperName), let data = try? Data(contentsOf: source),
              (try? CompatibilityFixes.begin(g)) != nil else { return }
        defer { CompatibilityFixes.end(g) }
        do {
            let ledger = CompatibilityFixes.journal(.nativeIPXNetworking, g)
            try ledger.validateForUndo()
            let rules = CompatibilityFixes.overrides(config.environment?["WINEDLLOVERRIDES"])
            guard state.appliedOverrides.allSatisfy({ rules[$0.key] == $0.value }),
                  (state.appliedEnvironment ?? [:]).allSatisfy({ config.environment?[$0.key] == $0.value }) else { return }
            let target = directory(g).appendingPathComponent(helperName)
            guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else { return }
            if FileManager.default.fileExists(atPath: target.path) {
                guard let owned = ledger.entries.last(where: { $0.path == target.path })?.shaAfter,
                      (try? Hashing.sha256(file: target)) == owned else { return }
            }
            try ledger.write(data, to: target, reason: "Updated session-based native IPX helper")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            state.nativeIPXRevision = revision
            try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(.nativeIPXNetworking, g), options: .atomic)
        } catch { return } // Preserve the recovery record; UI Update/Undo reports conflicts.
    }
    /// The administrator handoff runs only a verified, root-owned copy. The
    /// native helper detaches itself and confirms readiness through a pipe.
    static let permissionBootstrap = #"""
    set -euo pipefail
    [ "$(/usr/bin/id -u)" = 0 ] || { echo 'Native IPX authorization did not start as administrator.' >&2; exit 1; }
    ipx_source=$1
    ipx_owner=$2
    ipx_expected=$3
    [[ "$ipx_owner" =~ ^[0-9]+$ ]] && [ "$ipx_owner" -gt 0 ] || exit 1
    [[ "$ipx_expected" =~ ^[0-9a-f]{64}$ ]] || exit 1
    ipx_stage=$(/usr/bin/mktemp -d /private/tmp/nokcandu-ipx.XXXXXXXX)
    trap '/bin/rm -rf "$ipx_stage"' EXIT
    /bin/chmod 700 "$ipx_stage"
    /bin/cp "$ipx_source" "$ipx_stage/native-ipx-access"
    /bin/chmod 700 "$ipx_stage/native-ipx-access"
    ipx_actual=$(/usr/bin/shasum -a 256 "$ipx_stage/native-ipx-access")
    [ "${ipx_actual%% *}" = "$ipx_expected" ] || { echo 'Native IPX permission helper changed. Nothing was enabled.' >&2; exit 1; }
    "$ipx_stage/native-ipx-access" --enable "$ipx_owner" "$ipx_stage"
    trap - EXIT
    """#

    /// The profile records the component, never permission state. Only a user launch can prompt.
    /// Passwords stay in macOS' authorization dialog; neither Wine nor the game runs as root.
    static var launcherAccess: String {
        let data = resource.flatMap { try? Data(contentsOf: $0.appendingPathComponent(helperName)) }
        let sha = data.map { Hashing.sha256(data: $0) } ?? "missing"
        return #"""
        # Native IPX needs temporary packet access; ordinary UDP/TCP games do not.
        grep -q 'sikarugir 11\.0' "$SUPPORT/wine/version" || { echo 'Nokcandu: Native IPX needs the supported Wine 11 engine.'; exit 1; }
        IPX_HELPER="$SUPPORT/nokcandu/native-ipx/native-ipx-access"
        [ "$(/usr/bin/shasum -a 256 "$IPX_HELPER" | /usr/bin/awk '{print $1}')" = '\#(sha)' ] || { echo 'Nokcandu: Native IPX helper changed. Undo and reinstall Native IPX.'; exit 1; }
        IPX_SESSION_TOKEN=$("$IPX_HELPER" --register "$$") || { echo 'Nokcandu: Native IPX could not register this game session.'; exit 1; }
        if ! "$IPX_HELPER" --check; then
         /usr/bin/osascript - "$IPX_HELPER" "$(/usr/bin/id -u)" '\#(sha)' \#(CustomGames.shellQuote(permissionBootstrap)) <<'NOKCANDU_IPX_PERMISSION' || { "$IPX_HELPER" --unregister "$IPX_SESSION_TOKEN"; exit 1; }
        on run argv
         set helperPath to quoted form of item 1 of argv
         set ownerID to quoted form of item 2 of argv
         display dialog "Allow native IPX games to send and receive raw LAN packets while they are running? Access lasts through long matches and original permissions are restored after the last IPX game closes. Your games run with your normal account." with title "Native IPX" buttons {"Cancel", "Allow"} default button "Allow" cancel button "Cancel"
         set expectedSHA to quoted form of item 3 of argv
         set bootstrap to quoted form of item 4 of argv
         set rootCommand to "/bin/bash -p -c " & bootstrap & " ipx-bootstrap " & helperPath & " " & ownerID & " " & expectedSHA
         do shell script rootCommand with administrator privileges
        end run
        NOKCANDU_IPX_PERMISSION
         "$IPX_HELPER" --check || { "$IPX_HELPER" --unregister "$IPX_SESSION_TOKEN"; echo 'Nokcandu: Native IPX packet access was not enabled.'; exit 1; }
        fi

        """#
    }

}
