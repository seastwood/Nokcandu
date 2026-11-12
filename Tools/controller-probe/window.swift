// Standalone receipt/mapping diagnostic. C output is counted, never posted. No injection, saves,
// sensor activation, device mode writes, pairing or discovery requests.
import AppKit
import GameController

let app = NSApplication.shared
app.setActivationPolicy(.regular)
GCController.shouldMonitorBackgroundEvents = true
let menu = NSMenu()
let appItem = NSMenuItem(); let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Controller Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 400),
    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Nokcandu Controller Receipt Probe"
let label = NSTextField(wrappingLabelWithString: "Waiting for controller receipt…")
label.frame = NSRect(x: 20, y: 20, width: 640, height: 360)
window.contentView?.addSubview(label)
var seen = Set<ObjectIdentifier>()
var controls = 0, motion = 0
var lastMotion: Date?
var moves = 0, totalX = 0, totalY = 0
var maxProcessingUS = 0.0, receiptTime = 0.0
var sink = pe_sink()
sink.mouse_move = { _, x, y in
    moves += 1; totalX += Int(x); totalY += Int(y)
    if receiptTime > 0 { maxProcessingUS = max(maxProcessingUS, (ProcessInfo.processInfo.systemUptime - receiptTime) * 1_000_000) }
}
let engine = pe_create("nokpad 1\ngyro out=mouse min=10 max=10 smooth=0 tight=0 cal=off\nstick 1 mode=mouse sens=1000", sink)!

func refresh() {
    let connected = GCController.controllers()
    for c in connected where seen.insert(ObjectIdentifier(c)).inserted {
        c.handlerQueue = .main
        c.extendedGamepad?.valueChangedHandler = { pad, _ in
            controls += 1
            let now = ProcessInfo.processInfo.systemUptime
            pe_axis(engine, Int32(PE_AXIS_RX), Int32(pad.rightThumbstick.xAxis.value * 32767), now)
            pe_axis(engine, Int32(PE_AXIS_RY), Int32(-pad.rightThumbstick.yAxis.value * 32767), now)
        }
        c.motion?.valueChangedHandler = { sample in
            motion += 1; lastMotion = Date()
            receiptTime = ProcessInfo.processInfo.systemUptime
            let r = sample.rotationRate
            pe_gyro(engine, Float(r.x), Float(r.y), Float(r.z), receiptTime)
            receiptTime = 0
        }
    }
    let names = connected.map { "\($0.vendorName ?? $0.productCategory): gamepad=\($0.extendedGamepad != nil), motion=\($0.motion != nil)" }
    label.stringValue = "Connected GameController devices: \(connected.count)\n" + names.joined(separator: "\n") +
        "\nControl callbacks: \(controls)\nMotion callbacks: \(motion)\nLast motion: \(lastMotion.map { String(Int(Date().timeIntervalSince($0))) + " seconds ago" } ?? "not observed")\n\nRecorded engine mouse moves: \(moves)\nRecorded delta totals: \(totalX),\(totalY)\nMaximum callback-to-output processing: \(String(format: "%.1f", maxProcessingUS)) µs\n\nOutput is counted, NEVER injected into macOS or a game. No sensor activation, profile writes or permissions changed. Processing excludes hardware/OS scheduling and game consumption. Zero reports alone do not establish incompatibility or Steam exclusivity."
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
let delegate = Delegate(); app.delegate = delegate; window.delegate = delegate
let engineTimer = Timer(timeInterval: 0.004, repeats: true) { _ in pe_tick(engine, ProcessInfo.processInfo.systemUptime) }
RunLoop.main.add(engineTimer, forMode: .common)
let timer = Timer(timeInterval: 1, repeats: true) { _ in refresh() }
RunLoop.main.add(timer, forMode: .common)
refresh(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
app.run()
