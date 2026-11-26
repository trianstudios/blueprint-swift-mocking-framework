/// A predicate over the number of calls that match a verification query.
public struct CallCount: Sendable {
    // Sorted, disjoint, non-adjacent intervals over 0...Int.max.
    private let intervals: [ClosedRange<Int>]
    private let display: String?

    private init(intervals: [ClosedRange<Int>], display: String? = nil) {
        self.intervals = intervals
        self.display = display
    }

    public static var once: Self { .exactly(1) }
    public static var never: Self { .exactly(0) }

    public static func exactly(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(intervals: [value...value], display: "exactly \(value)")
    }

    public static func atLeast(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(intervals: [value...Int.max], display: "at least \(value)")
    }

    public static func atMost(_ value: Int) -> Self {
        precondition(value >= 0, "Call counts must be nonnegative")
        return Self(intervals: [0...value], display: "at most \(value)")
    }

    /// Creates a predicate that includes both bounds.
    public static func range(_ lower: Int, _ upper: Int) -> Self {
        precondition(lower >= 0 && upper >= 0, "Call counts must be nonnegative")
        precondition(lower <= upper, "Call count range bounds must be in ascending order")
        return Self(intervals: [lower...upper])
    }

    /// Creates a predicate that includes both bounds.
    public static func range(_ bounds: ClosedRange<Int>) -> Self {
        range(bounds.lowerBound, bounds.upperBound)
    }

    /// Whether at least one nonnegative count can satisfy this predicate.
    public var isSatisfiable: Bool { !intervals.isEmpty }

    /// Matches a count only if both predicates match it.
    public func and(_ other: Self) -> Self {
        if !isSatisfiable { return self }
        if !other.isSatisfiable { return other }
        var intersections: [ClosedRange<Int>] = []
        var left = 0
        var right = 0
        while left < intervals.count, right < other.intervals.count {
            let lhs = intervals[left]
            let rhs = other.intervals[right]
            let lower = max(lhs.lowerBound, rhs.lowerBound)
            let upper = min(lhs.upperBound, rhs.upperBound)
            if lower <= upper { intersections.append(lower...upper) }
            if lhs.upperBound <= rhs.upperBound { left += 1 }
            if rhs.upperBound <= lhs.upperBound { right += 1 }
        }
        let conflict = intersections.isEmpty ? "(\(description)) and (\(other.description))" : nil
        return Self(intervals: intersections, display: conflict)
    }

    /// Matches a count if either predicate matches it.
    public func or(_ other: Self) -> Self {
        if !isSatisfiable { return other }
        if !other.isSatisfiable { return self }
        let ordered = (intervals + other.intervals).sorted { $0.lowerBound < $1.lowerBound }
        var union: [ClosedRange<Int>] = []
        for interval in ordered {
            if let previous = union.last,
               previous.upperBound == Int.max || interval.lowerBound <= previous.upperBound + 1 {
                union[union.count - 1] = previous.lowerBound...max(previous.upperBound, interval.upperBound)
            } else {
                union.append(interval)
            }
        }
        return Self(intervals: union)
    }

    /// Matches exactly the nonnegative counts excluded by this predicate.
    public func not() -> Self {
        var complement: [ClosedRange<Int>] = []
        var next = 0
        for interval in intervals {
            if next < interval.lowerBound {
                complement.append(next...(interval.lowerBound - 1))
            }
            if interval.upperBound == Int.max {
                return Self(intervals: complement, display: complement.isEmpty ? "not (\(description))" : nil)
            }
            next = interval.upperBound + 1
        }
        complement.append(next...Int.max)
        return Self(intervals: complement)
    }

    func accepts(_ actual: Int) -> Bool {
        intervals.contains { $0.contains(actual) }
    }

    func failureMessage(observed: Int) -> String? {
        if !isSatisfiable {
            return "Contradictory call-count predicate: \(description). No nonnegative count can satisfy it; observed \(observed)."
        }
        if accepts(observed) { return nil }
        if let display { return "Expected \(display) calls; observed \(observed)" }
        return "Expected call count to match \(description); observed \(observed)"
    }

    var description: String {
        if let display { return display }
        let shown = intervals.prefix(3).map(Self.describe)
        let remaining = intervals.count - shown.count
        if remaining == 0 { return shown.joined(separator: " or ") }
        return shown.joined(separator: " or ") + " or \(remaining) more ranges"
    }

    private static func describe(_ interval: ClosedRange<Int>) -> String {
        let lower = interval.lowerBound
        let upper = interval.upperBound
        if lower == upper { return "exactly \(lower)" }
        if lower == 0, upper == Int.max { return "any nonnegative count" }
        if lower == 0 { return "at most \(upper)" }
        if upper == Int.max { return "at least \(lower)" }
        return "between \(lower) and \(upper) inclusive"
    }
}
