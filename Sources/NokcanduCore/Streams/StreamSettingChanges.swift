import Foundation

/// Which settings differ between two versions of a stream profile, by the names the stream profile's page shows
/// (lowercased), so the page can mark each one while a stream is running: the host fixes some when the stream
/// starts (they wait for the next stream), the rest take effect straight away (StreamWindowController.apply).
extension StreamProfile {
    public struct SettingChanges: Equatable, Sendable {
        /// Set when a stream starts: a change waits for the next stream.
        public var nextStream: Set<String> = []
        /// Take effect during the stream.
        public var live: Set<String> = []
    }

    public func settingChanges(from o: StreamProfile) -> SettingChanges {
        var c = SettingChanges()
        func next(_ changed: Bool, _ names: String...) { if changed { c.nextStream.formUnion(names) } }
        func live(_ changed: Bool, _ names: String...) { if changed { c.live.formUnion(names) } }
        // What the host is asked for when the stream starts.
        next(appID != o.appID, "starts")
        next(optimizeGameSettings != o.optimizeGameSettings, "optimize game settings")
        next(video.width != o.video.width || video.height != o.video.height, "resolution", "size in pixels")
        next(video.fps != o.video.fps, "frame rate")
        next(video.bitrateKbps != o.video.bitrateKbps, "bitrate")
        next(video.codec != o.video.codec, "codec")
        next(video.hdr != o.video.hdr, "hdr")
        next(video.yuv444 != o.video.yuv444, "full colour (4:4:4)")
        next(video.fullRange != o.video.fullRange, "full-range colour")
        next(audio.channels != o.audio.channels, "channels")
        next(audio.playOnHost != o.audio.playOnHost, "also play on the host")
        next(route != o.route, "connect through", "address")
        // What this Mac does with the stream.
        live(video.pacing != o.video.pacing, "frame pacing")
        live(video.frameBuffer != o.video.frameBuffer, "frames to buffer")
        live(window.display != o.window.display, "display")
        live(window.fullScreen != o.window.fullScreen, "full screen")
        live(window.statistics != o.window.statistics, "statistics")
        live(window.graphs != o.window.graphs, "performance graphs")
        live(controller.profileID != o.controller.profileID, "controller profile")
        live(controller.sendAs != o.controller.sendAs, "emulated controller type")
        live(controller.multipleControllers != o.controller.multipleControllers, "each controller is its own player")
        live(controller.swapFaceButtons != o.controller.swapFaceButtons, "swap a/b and x/y")
        live(controller.motion != o.controller.motion, "send motion")
        live(input.mouse != o.input.mouse, "mouse")
        live(input.keyboardLayout != o.input.keyboardLayout, "keyboard layout")
        live(input.reverseScroll != o.input.reverseScroll, "reverse scrolling")
        live(input.commandAsWindowsKey != o.input.commandAsWindowsKey, "⌘ is the windows key")
        live(input.captureSystemShortcuts != o.input.captureSystemShortcuts, "send mac shortcuts to the host")
        live(input.clipboard != o.input.clipboard, "share the clipboard")
        live(input.swapOptionCommand != o.input.swapOptionCommand, "swap ⌥ and ⌘")
        live(audio.outputDevice != o.audio.outputDevice, "play on")
        live(audio.volume != o.audio.volume, "volume")
        let v = audio.vban, w = o.audio.vban
        live(v.enabled != w.enabled, "send the microphone")
        live(v.inputDevice != w.inputDevice, "microphone")
        live(v.address != w.address || v.port != w.port, "send to")
        live(v.streamName != w.streamName, "stream name")
        live(v.channels != w.channels || v.sampleRate != w.sampleRate, "format")
        live(v.packetSamples != w.packetSamples, "network")
        live(v.gainDB != w.gainDB, "gain"); live(v.gate != w.gate, "noise gate"); live(v.compressor != w.compressor, "compressor")
        live(v.bassDB != w.bassDB, "bass"); live(v.midDB != w.midDB, "mid"); live(v.trebleDB != w.trebleDB, "treble")
        live(v.pushToTalk != w.pushToTalk, "push to talk")
        live(v.pushToTalkInput != w.pushToTalkInput, "talk while holding")
        return c
    }
}
