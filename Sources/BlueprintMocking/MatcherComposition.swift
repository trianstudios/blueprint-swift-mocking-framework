public extension Matcher where Input: AnyObject {
    /// Matches the same object reference. The matcher retains the expected object.
    static func identical(to expected: Input) -> Self {
        Self { $0 === expected }
    }
}

public extension Matcher {
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
    static func compose(_ operation: String, _ descriptions: [String?]) -> String? {
        guard descriptions.contains(where: { $0 != nil }) else { return nil }
        let operands = descriptions.map { $0 ?? "unnamed matcher" }.joined(separator: ", ")
        return "\(operation)(\(operands))"
    }

    static func countFailure(_ message: String, description: String?) -> String {
        guard let description else { return message }
        return "\(message)\nMatcher \(description)"
    }
}
