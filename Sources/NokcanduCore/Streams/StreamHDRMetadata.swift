// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NokcanduStreamCore

/// The host's HDR metadata (`LiGetHdrMetadata`) in the forms Core Video attaches to a frame, so macOS can
/// show HDR at the brightness it was mastered for and tonemap it on a display with less range. Follows
/// Moonlight PC (`VTBaseRenderer::setHdrMode`, attached per frame since 6.2.0).
public struct StreamHDRMetadata: Equatable {
    /// `kCVImageBufferMasteringDisplayColorVolumeKey`: SMPTE ST 2086 mastering display, 24 bytes big-endian,
    /// primaries in G, B, R order (the host sends R, G, B), then the white point, then max and min luminance
    /// in 1/10,000 nit.
    public var masteringDisplayColorVolume: Data?
    /// `kCVImageBufferContentLightLevelInfoKey`: MaxCLL and MaxFALL in nits, 4 bytes big-endian.
    public var contentLightLevelInfo: Data?

    public var isEmpty: Bool { masteringDisplayColorVolume == nil && contentLightLevelInfo == nil }

    public init(masteringDisplayColorVolume: Data? = nil, contentLightLevelInfo: Data? = nil) {
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    /// From the host's metadata. A part the host left as zeros is left out (macOS then uses its defaults).
    public init(_ m: SS_HDR_METADATA) {
        // Swift can't import the array of anonymous structs (`displayPrimaries`): it is the first field, three
        // pairs of UInt16 (x, y) in R, G, B order, read from the struct's bytes.
        var m = m
        let p: [UInt16] = withUnsafeBytes(of: &m) { raw in (0..<6).map { raw.load(fromByteOffset: $0 * 2, as: UInt16.self) } }
        self.init(primaries: [(p[0], p[1]), (p[2], p[3]), (p[4], p[5])], whitePoint: (m.whitePoint.x, m.whitePoint.y),
                  maxDisplayLuminance: m.maxDisplayLuminance, minDisplayLuminance: m.minDisplayLuminance,
                  maxContentLightLevel: m.maxContentLightLevel, maxFrameAverageLightLevel: m.maxFrameAverageLightLevel)
    }

    /// `primaries` in R, G, B order, normalised to 50,000; luminance: max in nits, min in 1/10,000 nit.
    public init(primaries: [(UInt16, UInt16)], whitePoint: (UInt16, UInt16), maxDisplayLuminance: UInt16, minDisplayLuminance: UInt16,
                maxContentLightLevel: UInt16, maxFrameAverageLightLevel: UInt16) {
        self.init()
        if primaries.count == 3, primaries[0].0 != 0, maxDisplayLuminance != 0 {
            var d = Data(capacity: 24)
            for i in [1, 2, 0] { Self.append16(primaries[i].0, &d); Self.append16(primaries[i].1, &d) }
            Self.append16(whitePoint.0, &d); Self.append16(whitePoint.1, &d)
            Self.append32(UInt32(maxDisplayLuminance) * 10_000, &d)
            Self.append32(UInt32(minDisplayLuminance), &d)
            masteringDisplayColorVolume = d
        }
        if maxContentLightLevel != 0, maxFrameAverageLightLevel != 0 {
            var d = Data(capacity: 4)
            Self.append16(maxContentLightLevel, &d); Self.append16(maxFrameAverageLightLevel, &d)
            contentLightLevelInfo = d
        }
    }

    /// The current metadata from the host, or nil when it has sent none.
    public static func current() -> StreamHDRMetadata? {
        var m = SS_HDR_METADATA()
        guard LiGetHdrMetadata(&m) else { return nil }
        let md = StreamHDRMetadata(m)
        return md.isEmpty ? nil : md
    }

    private static func append16(_ v: UInt16, _ d: inout Data) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xFF)) }
    private static func append32(_ v: UInt32, _ d: inout Data) { append16(UInt16(v >> 16), &d); append16(UInt16(v & 0xFFFF), &d) }
}
