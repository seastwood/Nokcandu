import XCTest
import NokcanduCore

final class Steam2026PictureGeometryTests: XCTestCase {
    typealias G = Steam2026PictureGeometry
    func testMirroredPhysicalControlsAndCardinalCaptions() {
        for width: CGFloat in [320, 400, 560, 800] {
            let g = G(width: width)
            for (left, right): (G.Control, G.Control) in [(.up, .y), (.down, .a), (.left, .b), (.right, .x), (.back, .start)] {
                XCTAssertEqual(g.center(left).x + g.center(right).x, 2 * g.body.midX, accuracy: 0.001)
                XCTAssertEqual(g.center(left).y, g.center(right).y, accuracy: 0.001)
            }
            for c: G.Control in [.y, .up] { XCTAssertLessThan(g.captionRect(c).maxY, g.controlRect(c).minY) }
            for c: G.Control in [.x, .left] { XCTAssertLessThan(g.captionRect(c).maxX, g.controlRect(c).minX) }
            for c: G.Control in [.b, .right] { XCTAssertGreaterThan(g.captionRect(c).minX, g.controlRect(c).maxX) }
            for c: G.Control in [.a, .down] { XCTAssertGreaterThan(g.captionRect(c).minY, g.controlRect(c).maxY) }
        }
    }
    func testAllAnnotationLanesAvoidControlsAndEachOtherAtSupportedSizes() {
        for width: CGFloat in [320, 400, 560, 800] {
            let g = G(width: width), canvas = CGRect(x: 0, y: 0, width: width, height: G.height(for: width))
            let controls = G.Control.allCases.map { ("button \($0)", g.controlRect($0)) }
                + (0..<2).map { ("stick \($0)", g.stickRect($0)) }
                + (0..<2).map { ("pad \($0)", g.padBounds($0)) } + [("gyro", g.gyro)]
            let captions = G.Control.allCases.map { ("caption \($0)", g.captionRect($0)) }
                + (0..<2).map { ("stick caption \($0)", g.stickCaptionRect($0)) }
                + (0..<2).map { ("pad caption \($0)", g.padCaptionRect($0)) }
            for (name, r) in controls + captions { XCTAssertTrue(canvas.contains(r), "\(name) outside \(width) canvas: \(r)") }
            for (name, r) in captions {
                for (other, rect) in controls { XCTAssertFalse(r.intersects(rect), "\(width): \(name) covers \(other)") }
            }
            for i in captions.indices {
                for j in captions.indices where j > i { XCTAssertFalse(captions[i].1.intersects(captions[j].1), "\(width): \(captions[i].0) overlaps \(captions[j].0)") }
            }
        }
    }
    func testPadAnglesAreMirroredAndGyroIsBelowBody() {
        let g = G(width: 560)
        XCTAssertEqual(G.padAngle(0), -G.padAngle(1)); XCTAssertGreaterThan(G.padAngle(0), 0)
        XCTAssertEqual(g.padBounds(0).width, g.padBounds(1).width, accuracy: 0.001)
        XCTAssertGreaterThan(g.padBounds(0).width, g.padRect(0).width)
        XCTAssertGreaterThan(g.gyro.minY, g.body.maxY)
        XCTAssertLessThan(g.stickCaptionRect(0).midX, g.stickRect(0).minX)
        XCTAssertGreaterThan(g.stickCaptionRect(1).midX, g.stickRect(1).maxX)
    }
    func testRotatedPadsStayInsideActualShellWithClearanceFromCutout() {
        for width: CGFloat in [320, 400, 560, 800] {
            let g = G(width: width), shell = G.shellPath(in: g.body)
            for side in 0..<2 {
                let pad = g.padRect(side), angle = G.padAngle(side) * .pi / 180
                let reach = pad.width / 2 + 4 * g.scale
                // Sample the expanded rotated square, a stricter check than the rounded surface itself.
                for step in 0...20 {
                    let offset = -reach + 2 * reach * CGFloat(step) / 20
                    for (x, y) in [(-reach, offset), (reach, offset), (offset, -reach), (offset, reach)] {
                        let p = CGPoint(x: pad.midX + cos(angle) * x - sin(angle) * y,
                                        y: pad.midY + sin(angle) * x + cos(angle) * y)
                        XCTAssertTrue(shell.contains(p), "\(width): pad \(side) leaves shell at \(p)")
                    }
                }
                XCTAssertGreaterThan(g.padBounds(side).minY, g.stickRect(side).maxY)
                XCTAssertLessThan(g.padBounds(side).maxY, g.body.minY + g.body.height * 0.774)
                XCTAssertEqual(pad.midY, g.center(.misc).y, accuracy: 0.001, "Pad and QAM centers align in the supplied front photo")
            }
        }
    }
}
