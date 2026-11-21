// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Nokcandu's recommended picture for a stream profile: the settings measured with the lowest latency on the
/// user's MacBook (November 19, 2026: ~8 ms from a frame's first packet to the screen, Metal with V-sync off).
/// New stream profiles start with them; a profile that differs shows "Use Recommended Settings".
extension StreamProfile {
    /// HEVC when the host encodes it (or hasn't said), otherwise Automatic, so a host without HEVC still streams.
    static func recommendedCodec(hostCodecModes: Int) -> Video.Codec {
        hostCodecModes == 0 || hostCodecModes & 0x180300 != 0 ? .hevc : .automatic      // SCM_MASK_HEVC
    }

    /// The picture settings this sets; everything else (the app, sound, controllers, Display) is left alone. The
    /// bitrate is left alone for a remote route (an internet connection needs its own limit).
    /// `displayFPS`: the refresh rate of the display the stream plays on; the frame rate follows it (the highest of
    /// the profile's choices at or below it), 60 when unknown.
    public mutating func applyRecommendedPicture(hostCodecModes: Int = 0, displayFPS: Int? = nil) {
        video.width = 2560; video.height = 1600
        video.fps = Self.recommendedFPS(displayFPS)
        if !route.isRemote { video.bitrateKbps = nil }
        video.codec = Self.recommendedCodec(hostCodecModes: hostCodecModes)
        video.hdr = false
        video.yuv444 = false
        video.renderer = .metal
        video.vsync = false
        video.pacing = .lowestLatency
        video.frameBuffer = nil
        video.fullRange = true
        window.fullScreen = true
        window.statistics = .off
        window.graphs = false
    }

    public static let frameRates = [30, 60, 90, 120, 144, 165, 240]
    /// At least 120: with V-sync off, a 60 Hz screen then shows frames up to 8 ms fresher (measured 3–4 ms less on
    /// average, November 21); a faster screen gets its own rate.
    public static func recommendedFPS(_ display: Int?) -> Int {
        guard let display, display > 120 else { return 120 }
        return frameRates.last(where: { $0 <= display }) ?? 120
    }

    public func usesRecommendedPicture(hostCodecModes: Int = 0, displayFPS: Int? = nil) -> Bool {
        var r = self
        r.applyRecommendedPicture(hostCodecModes: hostCodecModes, displayFPS: displayFPS)
        return r.video == video && r.window == window
    }
}
