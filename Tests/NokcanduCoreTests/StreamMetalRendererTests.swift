import XCTest
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
@testable import NokcanduCore

/// The Metal renderer drawing real frames on this Mac's GPU, offscreen: colours for every pixel format the decoder
/// produces, shape-keeping, and a full VideoToolbox encode → decode → draw round trip.
final class StreamMetalRendererTests: XCTestCase {
    private var renderer: StreamMetalRenderer!

    override func setUpWithError() throws {
        let (r, why) = StreamMetalRenderer.make(vsync: true)
        guard let r else { throw XCTSkip("No Metal here: \(why ?? "")") }
        renderer = r
    }

    // MARK: Synthetic frames

    private func buffer(_ format: OSType, width: Int = 64, height: Int = 64, y: Int, cb: Int, cr: Int,
                        matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        let b = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(b, [])
        let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                      kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!, row = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            let w = CVPixelBufferGetWidthOfPlane(b, plane), h = CVPixelBufferGetHeightOfPlane(b, plane)
            for j in 0..<h {
                if tenBit {
                    let p = (base + j * row).assumingMemoryBound(to: UInt16.self)
                    for i in 0..<w {
                        if plane == 0 { p[i] = UInt16(y << 6) } else { p[2 * i] = UInt16(cb << 6); p[2 * i + 1] = UInt16(cr << 6) }
                    }
                } else {
                    let p = (base + j * row).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<w {
                        if plane == 0 { p[i] = UInt8(y) } else { p[2 * i] = UInt8(cb); p[2 * i + 1] = UInt8(cr) }
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        return b
    }

    /// R, G, B at a pixel of the rendered picture.
    private func rgb(_ px: [UInt8], width: Int, x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(px[i + 2]), Int(px[i + 1]), Int(px[i])]
    }

    private func assertColour(_ format: OSType, y: Int, cb: Int, cr: Int, expect: [Int], tolerance: Int = 3,
                              matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let b = try buffer(format, y: y, cb: cb, cr: cr, matrix: matrix)
        let px = try XCTUnwrap(renderer.renderForTesting(b, width: 64, height: 64), "drew nothing", file: file, line: line)
        let got = rgb(px, width: 64, x: 32, y: 32)
        for (g, e) in zip(got, expect) {
            XCTAssertLessThanOrEqual(abs(g - e), tolerance, "\(what): got \(got), expected \(expect)", file: file, line: line)
        }
    }

    func testLimitedRange8BitBT709() throws {
        let f = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try assertColour(f, y: 235, cb: 128, cr: 128, expect: [255, 255, 255], "white")
        try assertColour(f, y: 16, cb: 128, cr: 128, expect: [0, 0, 0], "black")
        try assertColour(f, y: 126, cb: 128, cr: 128, expect: [128, 128, 128], "grey")
        try assertColour(f, y: 63, cb: 102, cr: 240, expect: [255, 0, 0], tolerance: 4, "red")
        try assertColour(f, y: 173, cb: 42, cr: 26, expect: [0, 255, 0], tolerance: 4, "green")
        try assertColour(f, y: 32, cb: 240, cr: 118, expect: [0, 0, 255], tolerance: 4, "blue")
    }

    func testFullRange8Bit() throws {
        let f = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        try assertColour(f, y: 255, cb: 128, cr: 128, expect: [255, 255, 255], "white")
        try assertColour(f, y: 0, cb: 128, cr: 128, expect: [0, 0, 0], "black")
        try assertColour(f, y: 54, cb: 99, cr: 255, expect: [255, 0, 0], tolerance: 4, "red")
    }

    func testTenBitAnd444() throws {
        try assertColour(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, y: 940, cb: 512, cr: 512, expect: [255, 255, 255],
                         matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, "10-bit white")
        try assertColour(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, y: 0, cb: 512, cr: 512, expect: [0, 0, 0],
                         matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, "10-bit full-range black")
        try assertColour(kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, y: 63, cb: 102, cr: 240, expect: [255, 0, 0], tolerance: 4, "4:4:4 red")
        try assertColour(kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, y: 940, cb: 512, cr: 512, expect: [255, 255, 255],
                         matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, "4:4:4 10-bit white")
    }

    /// A square picture in a wide target: centred, black bars left and right.
    func testShapeIsKept() throws {
        let b = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, y: 235, cb: 128, cr: 128)
        let px = try XCTUnwrap(renderer.renderForTesting(b, width: 128, height: 64))
        XCTAssertEqual(rgb(px, width: 128, x: 4, y: 32), [0, 0, 0], "left bar")
        XCTAssertEqual(rgb(px, width: 128, x: 123, y: 32), [0, 0, 0], "right bar")
        XCTAssertGreaterThan(rgb(px, width: 128, x: 64, y: 32)[0], 250, "picture")
    }

    /// Handing over frames never waits for the GPU or a drawable.
    func testSubmitDoesNotBlock() throws {
        renderer.resize(CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
        let b = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 2560, height: 1600, y: 126, cb: 128, cr: 128)
        let start = CACurrentMediaTime()
        for _ in 0..<240 { renderer.submit(.init(image: b, receivedAt: nil, decodedAt: CACurrentMediaTime())) }
        XCTAssertLessThan(CACurrentMediaTime() - start, 0.05, "240 submits took \((CACurrentMediaTime() - start) * 1000) ms")
    }

    /// One 2560×1600 frame drawn and finished on the GPU (what each streamed frame adds). The wall-clock time also
    /// includes making the test's target and reading 16 MB back, which a stream never does.
    func testDrawTimeAt1600p() throws {
        let b = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 2560, height: 1600, y: 126, cb: 128, cr: 128)
        _ = renderer.renderForTesting(b, width: 2560, height: 1600)
        var gpu: [Double] = [], wall: [Double] = []
        for _ in 0..<20 {
            let t = CACurrentMediaTime()
            _ = try XCTUnwrap(renderer.renderForTesting(b, width: 2560, height: 1600))
            wall.append((CACurrentMediaTime() - t) * 1000)
            gpu.append(renderer.lastGPUMillisecondsForTesting)
        }
        gpu.sort(); wall.sort()
        print(String(format: "Metal at 2560×1600: GPU median %.2f ms, max %.2f ms; test wall clock median %.2f ms", gpu[10], gpu.last!, wall[10]))
        // GitHub's macOS runners are virtual machines with an emulated GPU ("Apple Paravirtual device"), 6 ms a
        // frame there (November 19): the limit is for real hardware.
        let name = MTLCreateSystemDefaultDevice()?.name ?? "?"
        if name.localizedCaseInsensitiveContains("paravirtual") || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            throw XCTSkip("GPU timing on a virtual machine's GPU (\(name)): \(String(format: "%.2f", gpu[10])) ms")
        }
        XCTAssertLessThan(gpu[10], 3, "GPU time per frame")
    }

    // MARK: VideoToolbox round trip

    /// A frame with four colour quadrants, encoded and decoded by VideoToolbox as a stream is, then drawn: the
    /// decoder's real buffers and attachments go through the renderer.
    func testVideoToolboxRoundTrip() throws {
        for (codec, full) in [(kCMVideoCodecType_H264, false), (kCMVideoCodecType_H264, true), (kCMVideoCodecType_HEVC, true)] {
            let decoded = try roundTrip(codec: codec, fullRange: full)
            let px = try XCTUnwrap(renderer.renderForTesting(decoded, width: 256, height: 256))
            let label = "\(codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264") \(full ? "full" : "limited")"
            let expected: [(Int, Int, [Int])] = [(64, 64, [255, 0, 0]), (192, 64, [0, 255, 0]), (64, 192, [0, 0, 255]), (192, 192, [255, 255, 255])]
            for (x, y, e) in expected {
                let got = rgb(px, width: 256, x: x, y: y)
                for (g, c) in zip(got, e) { XCTAssertLessThanOrEqual(abs(g - c), 16, "\(label) at \(x),\(y): got \(got), expected \(e)") }
            }
        }
    }

    private func roundTrip(codec: CMVideoCodecType, fullRange: Bool) throws -> CVPixelBuffer {
        let w = 256, h = 256
        var source: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &source)
        let src = try XCTUnwrap(source)
        CVPixelBufferLockBaseAddress(src, [])
        let base = CVPixelBufferGetBaseAddress(src)!, row = CVPixelBufferGetBytesPerRow(src)
        for y in 0..<h {
            let p = (base + y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let c: [UInt8] = y < h / 2 ? (x < w / 2 ? [255, 0, 0] : [0, 255, 0]) : (x < w / 2 ? [0, 0, 255] : [255, 255, 255])
                p[4 * x] = c[2]; p[4 * x + 1] = c[1]; p[4 * x + 2] = c[0]; p[4 * x + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(src, [])
        CVBufferSetAttachment(src, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        var session: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                  compressionSessionOut: &session), noErr)
        let enc = try XCTUnwrap(session)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        var sample: CMSampleBuffer?
        let done = expectation(description: "encoded")
        VTCompressionSessionEncodeFrame(enc, imageBuffer: src, presentationTimeStamp: .zero, duration: .invalid, frameProperties: nil,
                                        infoFlagsOut: nil) { status, _, sb in
            XCTAssertEqual(status, noErr); sample = sb; done.fulfill()
        }
        VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
        wait(for: [done], timeout: 10)
        VTCompressionSessionInvalidate(enc)
        let encoded = try XCTUnwrap(sample)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(encoded))

        // Decoded into the buffers StreamVideoDecoder asks for.
        let pixel = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixel, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var dec: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &dec), noErr)
        let decoder = try XCTUnwrap(dec)
        var image: CVImageBuffer?
        let decoded = expectation(description: "decoded")
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: encoded, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            XCTAssertEqual(status, noErr); image = img; decoded.fulfill()
        }
        wait(for: [decoded], timeout: 10)
        VTDecompressionSessionInvalidate(decoder)
        let out = try XCTUnwrap(image)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), pixel)
        return out
    }
}
