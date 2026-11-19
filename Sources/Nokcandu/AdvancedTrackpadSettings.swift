import SwiftUI
import NokcanduCore

struct PadRegionSettings: View {
    @Binding var settings: PadSteamTrackpadSettings
    var region: Binding<PadMouseRegion> { Binding(get:{ settings.region ?? PadMouseRegion() },set:{ settings.region = $0 }) }
    var body: some View {
        Picker("Map to",selection:region.target) { ForEach(PadMouseRegion.Target.allCases,id:\.self) { Text($0.title).tag($0) } }
        percentage("Left",region.x); percentage("Top",region.y)
        percentage("Width",region.width); percentage("Height",region.height)
        Text("Over 100% stretches the pad past the area, so a round pad (the original Steam Controller's) can reach the corners. Around 140% reaches them.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Invert up and down",isOn:$settings.invertY)
        Text("The pad points directly at this part of the window or screen. Streams use the streamed display. For menus and inventories; games that lock the pointer need relative mouse mode.")
            .font(.caption).foregroundStyle(.secondary)
    }
    func percentage(_ title: String,_ value: Binding<Double>) -> some View {
        HStack { Text(title); Slider(value:value,in:(title == "Left" || title == "Top") ? 0...0.99 : 0.01...2); Text(value.wrappedValue,format:.percent.precision(.fractionLength(0))).monospacedDigit().frame(width:42) }
    }
}

struct PadGestureRecordButton: View {
    let side: Int
    let settings: PadSteamTrackpadSettings
    @Binding var pattern: String
    @State private var token: UUID?
    @State private var recognizer = PadGestureRecognizer()
    @State private var armed = false
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Button(token == nil ? "Record" : "Cancel Recording") { token == nil ? record() : stop() }
                .help("Touch the pad, draw up/down/left/right strokes, and lift. Recording pauses this controller's mapped output.")
            if token != nil {
                Text(armed ? "Draw on the pad, then lift to finish." : "Lift your finger to begin. Connect your controller if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onDisappear { stop() }
    }
    func record() {
        guard DesktopPad.shared.gestureRecorder == nil else { return }
        let id = UUID(); token = id; recognizer.reset(); armed = false
        DesktopPad.shared.gestureRecorder = id
        DesktopPad.shared.releaseForGestureRecording()
        SteamControllerUSB.shared.listen(id) { state in
            guard token == id, let state else { return }
            let down = side == 0 ? state.leftTouch : state.rightTouch
            let pad = side == 0 ? state.leftPad : state.rightPad
            if !armed { if !down { armed = true }; return }
            let point = settings.normalizedTouch(x:pad.x,y:pad.y)
            if let path = recognizer.update(down:down,x:Double(point.x),y:Double(point.y),stroke:settings.gestureStroke ?? 0.18) {
                pattern = path
                Task { @MainActor in stop() }
            }
        }
    }
    func stop() {
        guard let id = token else { return }
        token = nil; SteamControllerUSB.shared.remove(id)
        if DesktopPad.shared.gestureRecorder == id {
            DesktopPad.shared.gestureRecorder = nil
            DesktopPad.shared.evaluate(force:true)
        }
    }
}
