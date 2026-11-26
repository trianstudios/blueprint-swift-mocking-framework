import Foundation

public extension Matcher where Input: Comparable {
    static func inRange(_ bounds: ClosedRange<Input>) -> Self {
        Self { bounds.contains($0) }
    }

    static func inRange(_ bounds: Range<Input>) -> Self {
        Self { bounds.contains($0) }
    }

    /// Excludes both endpoints.
    static func openRange(_ lower: Input, _ upper: Input) -> Self {
        precondition(lower <= upper, "Range bounds must be in ascending order")
        return Self { lower < $0 && $0 < upper }
    }
}

public extension MainActorMatcher where Input: Comparable {
    static func inRange(_ bounds: ClosedRange<Input>) -> Self {
        Self { bounds.contains($0) }
    }

    static func inRange(_ bounds: Range<Input>) -> Self {
        Self { bounds.contains($0) }
    }

    /// Excludes both endpoints.
    static func openRange(_ lower: Input, _ upper: Input) -> Self {
        precondition(lower <= upper, "Range bounds must be in ascending order")
        return Self { lower < $0 && $0 < upper }
    }
}

public extension Matcher where Input: Collection {
    static func count(_ count: CallCount) -> Self {
        Self { count.accepts($0.count) }
    }
}

public extension Matcher where Input: Collection, Input.Element: Sendable {
    /// Requires the same length and matches each position in iteration order.
    static func orderedElements(_ expected: [Matcher<Input.Element>]) -> Self {
        Self { input in
            input.count == expected.count && zip(expected, input).allSatisfy { $0.matches($1) }
        }
    }

    /// Requires one distinct input position per matcher, including duplicate values.
    static func unorderedElements(_ expected: [Matcher<Input.Element>]) -> Self {
        Self { input in
            matchesMultiset(input, expected) { $0.matches($1) }
        }
    }

    static func allElements(_ matcher: Matcher<Input.Element>) -> Self {
        Self { input in input.allSatisfy { matcher.matches($0) } }
    }

    static func anyElement(_ matcher: Matcher<Input.Element>) -> Self {
        Self { input in input.contains { matcher.matches($0) } }
    }
}

public extension Matcher where Input: Collection, Input.Element: Equatable & Sendable {
    static func containsElement(_ expected: Input.Element) -> Self {
        Self { $0.contains(expected) }
    }
}

public extension MainActorMatcher where Input: Collection {
    static func count(_ count: CallCount) -> Self {
        Self { count.accepts($0.count) }
    }

    /// Requires the same length and matches each position in iteration order.
    static func orderedElements(_ expected: [MainActorMatcher<Input.Element>]) -> Self {
        Self { input in
            input.count == expected.count && zip(expected, input).allSatisfy { $0.matches($1) }
        }
    }

    /// Requires one distinct input position per matcher, including duplicate values.
    static func unorderedElements(_ expected: [MainActorMatcher<Input.Element>]) -> Self {
        Self { input in
            matchesMultiset(input, expected) { $0.matches($1) }
        }
    }

    static func allElements(_ matcher: MainActorMatcher<Input.Element>) -> Self {
        Self { input in input.allSatisfy { matcher.matches($0) } }
    }

    static func anyElement(_ matcher: MainActorMatcher<Input.Element>) -> Self {
        Self { input in input.contains { matcher.matches($0) } }
    }
}

public extension MainActorMatcher where Input: Collection, Input.Element: Equatable {
    static func containsElement(_ expected: Input.Element) -> Self {
        Self { $0.contains(expected) }
    }
}

public extension Matcher {
    /// A missing key never matches. A present optional value is passed to the value matcher.
    static func entry<Key: Hashable & Sendable, Value: Sendable>(
        _ key: Key, matching matcher: Matcher<Value>
    ) -> Self where Input == [Key: Value] {
        Self { dictionary in
            guard let value = dictionary[key] else { return false }
            return matcher.matches(value)
        }
    }
}

public extension MainActorMatcher {
    /// A missing key never matches. A present optional value is passed to the value matcher.
    static func entry<Key: Hashable, Value>(
        _ key: Key, matching matcher: MainActorMatcher<Value>
    ) -> Self where Input == [Key: Value] {
        Self { dictionary in
            guard let value = dictionary[key] else { return false }
            return matcher.matches(value)
        }
    }
}

private func matchesMultiset<Elements: Collection, Predicate>(
    _ input: Elements, _ expected: [Predicate], matches: (Predicate, Elements.Element) -> Bool
) -> Bool {
    guard input.count == expected.count else { return false }
    let values = Array(input)
    var candidates: [[Int]] = []
    var predicateForValue = [Int?](repeating: nil, count: values.count)
    var valueForPredicate = [Int?](repeating: nil, count: expected.count)

    // Search alternating paths in index order. A previously matched predicate can move to
    // a different candidate, so broad predicates do not consume a narrower predicate's only match.
    for root in expected.indices {
        let matchingPositions = values.indices.filter { matches(expected[root], values[$0]) }
        guard !matchingPositions.isEmpty else { return false }
        candidates.append(matchingPositions)
        var queue = [root]
        var current = 0
        var visited = [Bool](repeating: false, count: expected.count)
        visited[root] = true
        var predecessor = [Int?](repeating: nil, count: values.count)
        var freeValue: Int?
        while current < queue.count, freeValue == nil {
            let predicate = queue[current]
            current += 1
            for value in candidates[predicate] where predecessor[value] == nil {
                predecessor[value] = predicate
                if let occupiedBy = predicateForValue[value] {
                    if !visited[occupiedBy] {
                        visited[occupiedBy] = true
                        queue.append(occupiedBy)
                    }
                } else {
                    freeValue = value
                    break
                }
            }
        }
        guard freeValue != nil else { return false }

        // Follow the path back to the unmatched root and update each matched pair.
        while let value = freeValue, let predicate = predecessor[value] {
            freeValue = valueForPredicate[predicate]
            valueForPredicate[predicate] = value
            predicateForValue[value] = predicate
        }
    }
    return true
}

public extension Matcher where Input == String {
    /// An empty literal matches every string. Use comparison options here and regularExpression for a pattern.
    static func prefix(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .prefix, locale: locale))
    }

    static func suffix(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .suffix, locale: locale))
    }

    static func substring(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .anywhere, locale: locale))
    }

    /// Compiles an ICU expression at configuration and matches any occurrence in the input.
    static func regularExpression(_ pattern: String, options: NSRegularExpression.Options = []) throws -> Self {
        Self(try regexMatch(pattern, options: options))
    }
}

public extension MainActorMatcher where Input == String {
    /// An empty literal matches every string. Use comparison options here and regularExpression for a pattern.
    static func prefix(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .prefix, locale: locale))
    }

    static func suffix(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .suffix, locale: locale))
    }

    static func substring(_ value: String, options: String.CompareOptions = [], locale: Locale? = nil) -> Self {
        Self(textMatch(value, comparison: options, position: .anywhere, locale: locale))
    }

    /// Compiles an ICU expression at configuration and matches any occurrence in the input.
    static func regularExpression(_ pattern: String, options: NSRegularExpression.Options = []) throws -> Self {
        Self(try regexMatch(pattern, options: options))
    }
}

private enum TextMatchPosition {
    case prefix
    case suffix
    case anywhere
}

private func textMatch(
    _ value: String, comparison: String.CompareOptions, position: TextMatchPosition, locale: Locale?
) -> @Sendable (String) -> Bool {
    precondition(comparison.isDisjoint(with: [.anchored, .backwards, .regularExpression]),
                 "Choose the string matcher for anchoring, direction, or a regular expression")
    var options = comparison
    switch position {
    case .prefix:
        options.insert(.anchored)
    case .suffix:
        options.formUnion([.anchored, .backwards])
    case .anywhere:
        break
    }
    return { [options] input in
        value.isEmpty || input.range(of: value, options: options, locale: locale) != nil
    }
}

private func regexMatch(
    _ pattern: String, options: NSRegularExpression.Options
) throws -> @Sendable (String) -> Bool {
    let expression = try NSRegularExpression(pattern: pattern, options: options)
    return { input in
        expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }
}

/// By default NaNs never match, infinities match by exact value, and signed zeros compare equal.
public struct FloatingPointMatchOptions: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let matchNaNs = Self(rawValue: 1 << 0)
    public static let rejectInfinities = Self(rawValue: 1 << 1)
    public static let distinguishSignedZero = Self(rawValue: 1 << 2)
}

public extension Matcher where Input: BinaryFloatingPoint {
    /// Accepts either the absolute bound or the relative bound, scaled by the larger magnitude.
    /// Both tolerances must be finite and nonnegative.
    static func approximately(
        _ expected: Input, absoluteTolerance: Input = 0, relativeTolerance: Input = 0,
        options: FloatingPointMatchOptions = []
    ) -> Self {
        validateTolerances(absoluteTolerance, relativeTolerance)
        return Self { matchesFloatingPoint($0, expected, absoluteTolerance, relativeTolerance, options) }
    }
}

public extension MainActorMatcher where Input: BinaryFloatingPoint {
    /// Accepts either the absolute bound or the relative bound, scaled by the larger magnitude.
    /// Both tolerances must be finite and nonnegative.
    static func approximately(
        _ expected: Input, absoluteTolerance: Input = 0, relativeTolerance: Input = 0,
        options: FloatingPointMatchOptions = []
    ) -> Self {
        validateTolerances(absoluteTolerance, relativeTolerance)
        return Self { matchesFloatingPoint($0, expected, absoluteTolerance, relativeTolerance, options) }
    }
}

private func validateTolerances<Value: BinaryFloatingPoint>(_ absolute: Value, _ relative: Value) {
    precondition(absolute.isFinite && absolute >= 0 && relative.isFinite && relative >= 0,
                 "Floating-point tolerances must be finite and nonnegative")
}

private func matchesFloatingPoint<Value: BinaryFloatingPoint>(
    _ input: Value, _ expected: Value, _ absolute: Value, _ relative: Value,
    _ options: FloatingPointMatchOptions
) -> Bool {
    if input.isNaN || expected.isNaN {
        return options.contains(.matchNaNs) && input.isNaN && expected.isNaN
    }
    if input.isInfinite || expected.isInfinite {
        return !options.contains(.rejectInfinities) && input == expected
    }
    if input.isZero, expected.isZero, options.contains(.distinguishSignedZero) {
        return input.sign == expected.sign
    }
    let distance = (input - expected).magnitude
    if distance <= absolute { return true }
    if relative == 0 { return false }

    let scale = max(input.magnitude, expected.magnitude)
    if distance.isFinite { return distance / scale <= relative }
    // Finite subtraction can overflow only for opposite signs. Normalize before adding.
    return input.magnitude / scale + expected.magnitude / scale <= relative
}
