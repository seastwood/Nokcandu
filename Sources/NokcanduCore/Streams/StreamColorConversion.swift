// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The YUV-to-RGB conversion the Metal renderer's shader applies, from Moonlight PC
/// (`IFFmpegRenderer::getFramePremultipliedCscConstants` and `getFrameChromaCositingOffsets`, GPL-3.0): the
/// full-range matrix for the colour space, scaled for limited range, with the offsets subtracted first.
public enum StreamColorConversion {
    public enum Matrix: Sendable { case bt601, bt709, bt2020 }

    public struct Params: Equatable, Sendable {
        /// R, G and B as dot products with (Y, Cb, Cr) after `offsets` are subtracted.
        public var rows: [[Float]]
        public var offsets: [Float]
    }

    /// From a pixel buffer's `kCVImageBufferYCbCrMatrixKey` value; nil (unknown) is BT.709 for SDR, BT.2020 for 10-bit.
    public static func matrix(_ attachment: String?, tenBit: Bool) -> Matrix {
        switch attachment {
        case "ITU_R_601_4", "SMPTE_240M_1995": return .bt601
        case "ITU_R_709_2": return .bt709
        case "ITU_R_2020": return .bt2020
        default: return tenBit ? .bt2020 : .bt709
        }
    }

    public static func params(_ m: Matrix, fullRange: Bool, bits: Int) -> Params {
        // Columns: the Y, Cb and Cr coefficients for R, G, B (Moonlight's layout).
        let c: [Double]
        switch m {
        case .bt601: c = [1, 1, 1, 0, -0.3441, 1.7720, 1.4020, -0.7141, 0]
        case .bt709: c = [1, 1, 1, 0, -0.1873, 1.8556, 1.5748, -0.4681, 0]
        case .bt2020: c = [1, 1, 1, 0, -0.1646, 1.8814, 1.4746, -0.5714, 0]
        }
        let range = Double(1 << bits), top = range - 1, shift = Double(1 << (bits - 8))
        let yMin = fullRange ? 0 : 16 * shift, yMax = fullRange ? top : 235 * shift
        let uvMin = fullRange ? 0 : 16 * shift, uvMax = fullRange ? top : 240 * shift
        let yScale = top / (yMax - yMin), uvScale = top / (uvMax - uvMin)
        var s = c
        for i in 0..<3 { s[i] *= yScale }
        for i in 3..<9 { s[i] *= uvScale }
        let rows = (0..<3).map { r in [Float(s[r]), Float(s[r + 3]), Float(s[r + 6])] }
        let half = (range / 2) / top
        return Params(rows: rows, offsets: [Float(yMin / top), Float(half), Float(half)])
    }

    /// Where chroma samples sit relative to luma, in luma pixels (`kCVImageBufferChromaLocationTopFieldKey`),
    /// for 4:2:0; 4:4:4 has none. Unknown is "Left", the H.264/HEVC default.
    public static func chromaOffset(_ location: String?, subsampled: Bool) -> (x: Float, y: Float) {
        guard subsampled else { return (0, 0) }
        switch location {
        case "Center": return (0, 0)
        case "TopLeft": return (0.5, 0.5)
        case "Top": return (0, 0.5)
        case "BottomLeft": return (0.5, -0.5)
        case "Bottom": return (0, -0.5)
        default: return (0.5, 0)
        }
    }

    /// The picture's rectangle inside a drawable, keeping its shape, in normalised device coordinates
    /// (−1…1, y up): x, y of the lower left corner, width and height.
    public static func fit(width: Double, height: Double, in drawableWidth: Double, _ drawableHeight: Double) -> (x: Float, y: Float, w: Float, h: Float) {
        guard width > 0, height > 0, drawableWidth > 0, drawableHeight > 0 else { return (-1, -1, 2, 2) }
        let scale = min(drawableWidth / width, drawableHeight / height)
        let w = width * scale / drawableWidth * 2, h = height * scale / drawableHeight * 2
        return (Float(-w / 2), Float(-h / 2), Float(w), Float(h))
    }
}
