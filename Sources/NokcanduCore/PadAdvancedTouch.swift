import Foundation

/// Fractions of the chosen surface, independent of its resolution and display scale.
public struct PadMouseRegion: Codable, Hashable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case window, screen
        public var title: String { self == .window ? "Front window" : "Current screen" }
    }
    public var target: Target = .window
    public var x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1
    public init() {}
    public func point(x px: Double, y py: Double) -> CGPoint? {
        guard [x,y,width,height,px,py].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let left = max(0, min(0.99, x)), top = max(0, min(0.99, y))
        // Up to 100%: that part of the surface, as before. Over 100% (up to 200%): stretched past it around the
        // region's center, so a round pad (the original Steam Controller's) reaches the corners; points beyond
        // the surface stop at its edge.
        func axis(_ start: Double, _ size: Double, _ p: Double) -> Double {
            let fitted = min(size, 1 - start), span = size > 1 ? min(size, 2) : fitted
            return max(0, min(1, start + fitted / 2 + (max(0, min(1, p)) - 0.5) * span))
        }
        return CGPoint(x: axis(left, width, px), y: axis(top, height, py))
    }
    public func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 1, bounds.height > 1, let p = point(x:x,y:y) else { return nil }
        return CGPoint(x: bounds.minX + p.x * (bounds.width-1), y: bounds.minY + p.y * (bounds.height-1))
    }
}

/// Drawn cardinal strokes. No action is emitted until the finger lifts. The stored path and edit work
/// are bounded; profile/focus/disconnection changes discard a partial gesture rather than completing it.
public struct PadGestureRecognizer {
    public private(set) var path = ""
    private var down = false
    private var overflow = false
    private var anchor = CGPoint.zero
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func update(down touching: Bool, x: Double, y: Double, stroke: Double = 0.18) -> String? {
        guard x.isFinite, y.isFinite else { reset(); return nil }
        if !touching {
            let result = down && !overflow && !path.isEmpty ? path : nil
            reset(); return result
        }
        let p = CGPoint(x:max(0,min(1,x)), y:max(0,min(1,y)))
        guard down else { down = true; anchor = p; return nil }
        let dx = p.x-anchor.x, dy = p.y-anchor.y
        guard hypot(dx,dy) >= max(0.05,min(0.5,stroke.isFinite ? stroke : 0.18)) else { return nil }
        let next: Character = abs(dx) >= abs(dy) ? (dx > 0 ? "R":"L") : (dy > 0 ? "D":"U")
        if path.last != next { if path.count < 24 { path.append(next) } else { overflow = true } }
        anchor = p
        return nil
    }
    public static func normalized(_ pattern: String) -> String {
        var result = ""
        for c in pattern.uppercased() where "UDLR".contains(c) {
            if result.last != c, result.count < 24 { result.append(c) }
        }
        return result
    }
    public static func match(_ path: String, patterns: [String], tolerance: Double = 0) -> Int? {
        let drawn = Array(normalized(path)); guard !drawn.isEmpty else { return nil }
        var best: (index:Int, score:Double)?
        let limit = max(0,min(0.5,tolerance.isFinite ? tolerance:0))
        for (index, pattern) in patterns.prefix(4).enumerated() {
            let target = Array(normalized(pattern)); guard !target.isEmpty else { continue }
            var row = Array(0...target.count)
            for (i, a) in drawn.enumerated() {
                var next = [i+1] + Array(repeating:0,count:target.count)
                for (j,b) in target.enumerated() { next[j+1] = min(next[j]+1,row[j+1]+1,row[j]+(a==b ? 0:1)) }
                row = next
            }
            let score = Double(row.last!)/Double(max(drawn.count,target.count))
            if score <= limit, best == nil || score < best!.score { best = (index,score) }
        }
        return best?.index
    }
}
