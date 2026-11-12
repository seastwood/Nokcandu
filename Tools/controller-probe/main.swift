// Read-only, process-local GameController receipt probe. No event injection,
// device mode writes, profile persistence, raw reports or controller discovery/pairing.
import AppKit
import GameController

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
GCController.shouldMonitorBackgroundEvents = true
var seen = Set<ObjectIdentifier>()
var buttonReports = 0, motionReports = 0
func attach() {
    for controller in GCController.controllers() {
        guard seen.insert(ObjectIdentifier(controller)).inserted else { continue }
        print("controller: \(controller.vendorName ?? controller.productCategory); extended=\(controller.extendedGamepad != nil); motion=\(controller.motion != nil)")
        controller.extendedGamepad?.valueChangedHandler = { _, _ in buttonReports += 1 }
        // Deliberately do not change sensorsActive: observe current accessibility only.
        controller.motion?.valueChangedHandler = { _ in motionReports += 1 }
    }
}
let token = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in attach() }
attach()
RunLoop.main.run(until: Date().addingTimeInterval(3))
attach()
NotificationCenter.default.removeObserver(token)
print("summary: controllers=\(seen.count); control callbacks=\(buttonReports); motion callbacks=\(motionReports)")
print("Receipt only; zero reports do not prove device incompatibility or Steam exclusivity.")
