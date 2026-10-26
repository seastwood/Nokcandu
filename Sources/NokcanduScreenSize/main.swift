// nokcandu screen-size tool.
//   screen-size                          prints the main display's scaled desktop size, e.g. "1470 956"
//   screen-size --list                   prints the resolutions the main display can run: "pixelW pixelH"
//   screen-size --play W H --watch RE    switches the main display to exactly W×H pixels while a game runs:
//                                        waits for a process whose command matches RE to start, then for
//                                        it to quit, and puts the desktop back (also on SIGTERM/SIGINT/SIGHUP).
// The desktop mode is saved in a file first, so a run that was killed is undone by the next one.
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)        // log lines appear as they happen
let display = CGMainDisplayID()
let args = Array(CommandLine.arguments.dropFirst())

func allModes() -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    return ((CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
}

/// The 1× mode with exactly these pixels: Wine then sees the screen as exactly this many pixels, with
/// no Retina scaling in between (Wine's Retina mode mis-sizes game windows).
func mode(pixels w: Int, _ h: Int) -> CGDisplayMode? {
    let rate = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
    return allModes().filter { $0.pixelWidth == w && $0.pixelHeight == h }.sorted { a, b in
        let a1 = a.width == a.pixelWidth, b1 = b.width == b.pixelWidth
        if a1 != b1 { return a1 }
        return abs(a.refreshRate - rate) < abs(b.refreshRate - rate)
    }.first
}

func mode(points w: Int, _ h: Int, pixels pw: Int, _ ph: Int) -> CGDisplayMode? {
    allModes().first { $0.width == w && $0.height == h && $0.pixelWidth == pw && $0.pixelHeight == ph }
}

@discardableResult
func apply(_ m: CGDisplayMode) -> Bool {
    var c: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&c) == .success else { return false }
    CGConfigureDisplayWithDisplayMode(c, display, m, nil)
    return CGCompleteDisplayConfiguration(c, .forSession) == .success
}

func describe(_ m: CGDisplayMode) -> String { "\(m.width) \(m.height) \(m.pixelWidth) \(m.pixelHeight)" }

if args.isEmpty {
    if let m = CGDisplayCopyDisplayMode(display), m.width > 0, m.height > 0 { print("\(m.width) \(m.height)") } else { print("1280 800") }
    exit(0)
}

if args.first == "--list" {
    var seen = Set<String>()
    for m in allModes().sorted(by: { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }) {
        let k = "\(m.pixelWidth) \(m.pixelHeight)"
        if seen.insert(k).inserted { print(k) }
    }
    exit(0)
}

guard args.count >= 5, args[0] == "--play", let w = Int(args[1]), let h = Int(args[2]), args[3] == "--watch",
      let regex = try? NSRegularExpression(pattern: args[4], options: [.caseInsensitive]) else {
    FileHandle.standardError.write(Data("usage: screen-size [--list | --play W H --watch REGEX]\n".utf8)); exit(2)
}

let stateFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Nokcandu/display-restore")
try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)

// The desktop to come back to: one saved by a run that never finished, or the current one.
var saved: CGDisplayMode?
if let s = try? String(contentsOf: stateFile, encoding: .utf8) {
    let n = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
    if n.count == 4 { saved = mode(points: n[0], n[1], pixels: n[2], n[3]) }
}
// The desktop is whatever the screen is set to now — any size, Retina or not. The one exception: the
// screen is already at exactly this game's mode with no saved desktop (an earlier run was killed before it
// could restore). Then the real desktop is unknown, so leave the screen as it is afterwards.
func sensibleDesktop() -> CGDisplayMode? { CGDisplayCopyDisplayMode(display) }
guard let desktop = saved ?? sensibleDesktop(), let game = mode(pixels: w, h) else {
    print("display: no \(w)x\(h) mode on this display; leaving it alone"); exit(1)
}
try? describe(desktop).write(to: stateFile, atomically: true, encoding: .utf8)

func restore() {
    if let cur = CGDisplayCopyDisplayMode(display), describe(cur) != describe(desktop) { apply(desktop) }
    try? FileManager.default.removeItem(at: stateFile)
}
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { restore(); exit(0) }
    src.resume()
    sources.append(src)
}

if let cur = CGDisplayCopyDisplayMode(display), describe(cur) != describe(game) { apply(game) }
print("display: \(describe(game)) while the game runs (desktop \(describe(desktop)))")

func gameRunning() -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "command="]
    let out = Pipe(); p.standardOutput = out
    guard (try? p.run()) != nil else { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

// Wait up to 10 minutes for the game (Steam may update it first), then until it has been gone ~10 s.
DispatchQueue.global().async {
    var seen = false, gone = 0, waited = 0
    while true {
        Thread.sleep(forTimeInterval: 2)
        if gameRunning() { seen = true; gone = 0 }
        else if seen { gone += 1; if gone >= 5 { break } }
        else { waited += 2; if waited >= 600 { break } }
    }
    DispatchQueue.main.async { restore(); print("display: desktop back"); exit(0) }
}
dispatchMain()
