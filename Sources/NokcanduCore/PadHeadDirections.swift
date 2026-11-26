import Foundation

/// Headphone motion as a radial menu: which direction the head is turned to (one of 4 or 8, clockwise from up),
/// once it's turned far enough. Holds the choice steady near the edges between directions and near the
/// threshold, so a still head doesn't flicker between two.
public struct PadHeadDirections: Sendable {
    public private(set) var chosen: Int?          // 0…7, clockwise from up (four use 0, 2, 4, 6)
    public init() {}
    public mutating func reset() { chosen = nil }

    /// x right, y up, both −1…1 of the full range. Returns the direction now held (nil: none).
    public mutating func update(x: Double, y: Double, sectors: Int, selectAt: Double) -> Int? {
        let n = sectors == 8 ? 8 : 4, m = (x * x + y * y).squareRoot()
        guard x.isFinite, y.isFinite, m >= (chosen == nil ? selectAt : selectAt * 0.8) else { chosen = nil; return nil }
        let a = (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)     // clockwise from up
        let width = 360.0 / Double(n)
        func centre(_ i: Int) -> Double { Double(i) * 45 }
        func off(_ i: Int) -> Double { let d = abs(a - centre(i)).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
        // Stay with the one held until the head is a little past its edge.
        if let c = chosen, off(c) <= width / 2 + 6 { return c }
        let step = 8 / n
        chosen = (Int(((a + width / 2) / width).rounded(.down)) % n) * step
        return chosen
    }

    public static func inputs(_ sectors: Int) -> [PadProfiles.Input] {
        sectors == 8 ? PadProfiles.Input.headDirections : [.hm1, .hm3, .hm5, .hm7]
    }
}
