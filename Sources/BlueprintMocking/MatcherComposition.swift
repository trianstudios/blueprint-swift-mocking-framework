public extension Matcher where Input: AnyObject {
    /// Matches the same object reference. The matcher retains the expected object.
    static func identical(to expected: Input) -> Self {
        Self { $0 === expected }
    }
}

public extension Matcher {
    /// Builds a matcher with explicit descriptions from the source fields it tests.
    /// Supply fields in source order. An unlabeled argument uses its Swift label, "_".
    static func matchingFields(
        _ fields: [(label: String, description: String?)],
        _ predicate: @escaping @Sendable (Input) -> Bool
    ) -> Self {
        Self(description: MatcherDescription.fields(fields), predicate)
    }

    /// Matches a typed payload extracted from the input. Returning nil skips the payload matcher.
    /// For an optional payload, return .some(nil) to match the case carrying nil.
    /// Keep the extractor pure, bounded, and nonblocking.
    static func projecting<Payload: Sendable>(
        _ extract: @escaping @Sendable (Input) -> Payload?,
        matching matcher: Matcher<Payload>
    ) -> Self {
        Self(description: MatcherDescription.compose("projecting", [matcher.description])) { input in
            guard let payload = extract(input) else { return false }
            return matcher.matches(payload)
        }
    }

    /// Matches an Optional.none without requiring its wrapped value to be Equatable.
    static func isNil<Wrapped: Sendable>() -> Self where Input == Wrapped? {
        Self { $0 == nil }
    }

    /// Matches a present value and optionally applies a matcher to that value.
    static func nonNil<Wrapped: Sendable>(_ wrapped: Matcher<Wrapped> = .any) -> Self
    where Input == Wrapped? {
        Self(description: MatcherDescription.compose("nonNil", [wrapped.description])) { input in
            guard let value = input else { return false }
            return wrapped.matches(value)
        }
    }

    /// The predicate may be evaluated more than once. Keep it pure, bounded, and nonblocking.
    static func satisfying(_ predicate: @escaping @Sendable (Input) -> Bool) -> Self {
        Self(predicate)
    }

    /// Evaluates left to right and stops after the first mismatch. An empty list matches.
    static func allOf(_ matchers: Self...) -> Self {
        Self(description: MatcherDescription.compose("allOf", matchers.map(\.description))) { input in
            matchers.allSatisfy { $0.matches(input) }
        }
    }

    /// Evaluates left to right and stops after the first match. An empty list never matches.
    static func anyOf(_ matchers: Self...) -> Self {
        Self(description: MatcherDescription.compose("anyOf", matchers.map(\.description))) { input in
            matchers.contains { $0.matches(input) }
        }
    }

    func and(_ other: Self) -> Self {
        Self(description: MatcherDescription.compose("and", [description, other.description])) {
            self.matches($0) && other.matches($0)
        }
    }

    func or(_ other: Self) -> Self {
        Self(description: MatcherDescription.compose("or", [description, other.description])) {
            self.matches($0) || other.matches($0)
        }
    }

    func not() -> Self {
        Self(description: MatcherDescription.compose("not", [description])) { !self.matches($0) }
    }
}

public extension MainActorMatcher where Input: AnyObject {
    /// Matches the same object reference. The matcher retains the expected object on the main actor.
    static func identical(to expected: Input) -> Self {
        Self { $0 === expected }
    }
}

public extension MainActorMatcher {
    /// Builds an actor-local matcher with explicit descriptions from its source fields.
    /// Supply fields in source order. An unlabeled argument uses its Swift label, "_".
    static func matchingFields(
        _ fields: [(label: String, description: String?)],
        _ predicate: @escaping @MainActor (Input) -> Bool
    ) -> Self {
        Self(description: MatcherDescription.fields(fields), predicate)
    }

    /// Extracts and matches a typed payload on the main actor. Returning nil skips the payload matcher.
    /// For an optional payload, return .some(nil) to match the case carrying nil.
    /// Keep the extractor pure, bounded, and nonblocking.
    static func projecting<Payload>(
        _ extract: @escaping @MainActor (Input) -> Payload?,
        matching matcher: MainActorMatcher<Payload>
    ) -> Self {
        Self(description: MatcherDescription.compose("projecting", [matcher.description])) { input in
            guard let payload = extract(input) else { return false }
            return matcher.matches(payload)
        }
    }

    /// Matches an Optional.none without requiring its wrapped value to be Equatable.
    static func isNil<Wrapped>() -> Self where Input == Wrapped? {
        Self { $0 == nil }
    }

    /// Matches a present value and optionally applies a matcher to that value on the main actor.
    static func nonNil<Wrapped>(_ wrapped: MainActorMatcher<Wrapped> = .any) -> Self
    where Input == Wrapped? {
        Self(description: MatcherDescription.compose("nonNil", [wrapped.description])) { input in
            guard let value = input else { return false }
            return wrapped.matches(value)
        }
    }

    /// The predicate runs on the main actor. Keep it pure, bounded, and nonblocking.
    static func satisfying(_ predicate: @escaping @MainActor (Input) -> Bool) -> Self {
        Self(predicate)
    }

    /// Evaluates left to right and stops after the first mismatch. An empty list matches.
    static func allOf(_ matchers: Self...) -> Self {
        Self(description: MatcherDescription.compose("allOf", matchers.map(\.description))) { input in
            matchers.allSatisfy { $0.matches(input) }
        }
    }

    /// Evaluates left to right and stops after the first match. An empty list never matches.
    static func anyOf(_ matchers: Self...) -> Self {
        Self(description: MatcherDescription.compose("anyOf", matchers.map(\.description))) { input in
            matchers.contains { $0.matches(input) }
        }
    }

    func and(_ other: Self) -> Self {
        Self(description: MatcherDescription.compose("and", [description, other.description])) {
            self.matches($0) && other.matches($0)
        }
    }

    func or(_ other: Self) -> Self {
        Self(description: MatcherDescription.compose("or", [description, other.description])) {
            self.matches($0) || other.matches($0)
        }
    }

    func not() -> Self {
        Self(description: MatcherDescription.compose("not", [description])) { !self.matches($0) }
    }
}

enum MatcherDescription {
    private static let unnamed = "unnamed matcher"
    // Composed descriptions and count-failure messages share a 4 KiB UTF-8 budget.
    private static let maximumBytes = 4_096
    private static let truncationMarker = "… [truncated]"

    static func fields(_ fields: [(label: String, description: String?)]) -> String? {
        guard fields.contains(where: { $0.description != nil }) else { return nil }
        var writer = Writer()
        writer.append("fields(")
        for (index, field) in fields.enumerated() {
            if writer.isTruncated { break }
            if index > 0 { writer.append(", ") }
            writer.append(field.label)
            writer.append(": ")
            writer.append(field.description ?? unnamed)
        }
        writer.append(")")
        return writer.rendered
    }

    static func compose(_ operation: String, _ descriptions: [String?]) -> String? {
        guard descriptions.contains(where: { $0 != nil }) else { return nil }
        var writer = Writer()
        writer.append(operation)
        writer.append("(")
        for (index, description) in descriptions.enumerated() {
            if writer.isTruncated { break }
            if index > 0 { writer.append(", ") }
            writer.append(description ?? unnamed)
        }
        writer.append(")")
        return writer.rendered
    }

    static func countFailure(_ message: String, description: String?) -> String {
        var writer = Writer()
        writer.append(message)
        if let description {
            writer.append("\nMatcher ")
            writer.append(description)
        }
        return writer.rendered
    }

    private struct Writer {
        private var bytes: [UInt8] = []
        private(set) var isTruncated = false

        mutating func append(_ fragment: String) {
            guard !isTruncated else { return }
            // Read one extra byte to distinguish an exact fit from truncation.
            bytes.append(contentsOf: fragment.utf8.prefix(maximumBytes + 1 - bytes.count))
            guard bytes.count > maximumBytes else { return }

            let suffix = truncationMarker.utf8
            var end = maximumBytes - suffix.count
            // The first byte omitted cannot be a continuation byte of a retained scalar.
            while bytes[end] & 0xC0 == 0x80 { end -= 1 }
            bytes.removeSubrange(end...)
            bytes.append(contentsOf: suffix)
            isTruncated = true
        }

        var rendered: String { String(decoding: bytes, as: UTF8.self) }
    }
}
