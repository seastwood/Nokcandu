import Foundation

/// Retains physical source identity while composing the main controller inputs.
/// Buttons combine as holds; each axis uses the strongest source (stable ID breaks ties).
public struct PadSourceState {
    public struct Changes {
        public var buttons: [(Int, Bool)]
        public var axes: [(Int, Int)]
    }
    private struct State { var buttons: Set<Int>; var axes: [Int: Int] }
    private var sources: [String: State] = [:]
    private var buttons = Set<Int>()
    private var axes: [Int: Int] = [:]
    public init() {}
    public mutating func update(source: String, buttons: Set<Int>, axes: [Int: Int]) -> Changes {
        sources[source] = State(buttons: buttons, axes: axes); return changes()
    }
    public mutating func retain(_ connected: Set<String>) -> Changes {
        sources = sources.filter { connected.contains($0.key) }; return changes()
    }
    private mutating func changes() -> Changes {
        let nextButtons = sources.values.reduce(into: Set<Int>()) { $0.formUnion($1.buttons) }
        var nextAxes: [Int: Int] = [:]
        for id in sources.keys.sorted() {
            for (a, v) in sources[id]!.axes where abs(v) > abs(nextAxes[a] ?? 0) { nextAxes[a] = v }
        }
        let changedButtons = buttons.symmetricDifference(nextButtons).sorted().map { ($0, nextButtons.contains($0)) }
        let changedAxes = Set(axes.keys).union(nextAxes.keys).sorted().compactMap { a -> (Int, Int)? in
            let v = nextAxes[a] ?? 0; return v != (axes[a] ?? 0) ? (a, v) : nil
        }
        buttons = nextButtons; axes = nextAxes
        return Changes(buttons: changedButtons, axes: changedAxes)
    }
}
