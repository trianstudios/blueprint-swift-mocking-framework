/// Value copies recorded before and after a call-scoped mutation.
public struct InoutValues<Value: Sendable>: Sendable {
    /// The value used to match the stub when the invocation was admitted.
    public let before: Value

    /// The terminal value, once available. An optional value of nil is still a completed value.
    /// Reference-typed values preserve their identity and do not copy the referenced object's state.
    public let after: Value?
}

extension InoutValues: Equatable where Value: Equatable {}

// A Result-backed closure preserves the exact typed error on older deployment targets.
private typealias InoutSyncAnswer<Value, Output, Failure: Error> =
    @Sendable (inout Value) -> Result<Output, Failure>

private func inoutSyncAnswer<Value, Output, Failure: Error>(
    _ answer: @escaping @Sendable (inout Value) throws(Failure) -> Output
) -> InoutSyncAnswer<Value, Output, Failure> {
    { value in
        do throws(Failure) { return .success(try answer(&value)) }
        catch { return .failure(error) }
    }
}

public typealias InoutSyncConfiguration<Value: Sendable, Output: Sendable> =
    InoutSyncThrowingConfiguration<Value, Output, Never>
public typealias InoutSyncStubbing<Value: Sendable, Output: Sendable> =
    InoutSyncThrowingStubbing<Value, Output, Never>
public typealias InoutSyncStub<Value: Sendable, Output: Sendable> =
    InoutSyncThrowingStub<Value, Output, Never>

public struct InoutSyncThrowingConfiguration<Value: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [Rule<Value, InoutSyncAnswer<Value, Output, Failure>>]
}

public final class InoutSyncThrowingStubbing<Value: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let builder = EffectRulesBuilder<Value, InoutSyncAnswer<Value, Output, Failure>>()

    public init() {}

    public func matching(_ matcher: Matcher<Value>) -> InoutSyncThrowingStub<Value, Output, Failure> {
        InoutSyncThrowingStub(owner: self, matcher: matcher)
    }

    public func finish() -> InoutSyncThrowingConfiguration<Value, Output, Failure> {
        InoutSyncThrowingConfiguration(rules: builder.finish())
    }
}

public struct InoutSyncThrowingStub<Value: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let owner: InoutSyncThrowingStubbing<Value, Output, Failure>
    fileprivate let matcher: Matcher<Value>

    public func willReturn(_ output: Output) {
        owner.builder.add(matcher) { _ in .success(output) }
    }

    public func willThrow(_ error: Failure) {
        owner.builder.add(matcher) { _ in .failure(error) }
    }

    public func willAnswer(_ answer: @escaping @Sendable (inout Value) throws(Failure) -> Output) {
        owner.builder.add(matcher, inoutSyncAnswer(answer))
    }
}

/// A real implementation called with the caller's scoped inout access.
public struct InoutSyncThrowingForwarding<Value: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let answer: InoutSyncAnswer<Value, Output, Failure>

    public init(_ answer: @escaping @Sendable (inout Value) throws(Failure) -> Output) {
        self.answer = inoutSyncAnswer(answer)
    }
}

private struct InoutSyncDispatch<Value: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let journal: Journal<InoutValues<Value>>
    let configuration: InoutSyncThrowingConfiguration<Value, Output, Failure>
    let forwarding: InoutSyncAnswer<Value, Output, Failure>?
    let fallback: (@Sendable (MockIssue) -> Result<Output, Failure>)?

    func invoke(_ value: inout Value, source: SourceLocation) throws(Failure) -> Output {
        let before = value
        guard let admission = journal.begin(InoutValues(before: before, after: nil)) else {
            let issue = journal.reportFinishedCall(source: source)
            guard let fallback else { fatalError(issue.message) }
            return try fallback(issue).get()
        }

        // The original access is passed directly while the answer executes, outside journal locks.
        let stub = configuration.rules.reversed().first { $0.matcher.matches(before) }
        let result: Result<Output, Failure>
        let origin: CallOrigin?
        if let answer = stub?.answer ?? forwarding {
            result = answer(&value)
            origin = stub == nil ? .forwarded : nil
        } else {
            origin = nil
            guard let fallback else {
                journal.complete(admission, phase: .terminated, replacing: InoutValues(before: before, after: .some(value)))
                let issue = journal.reportMissingCall(admission, source: source)
                fatalError(issue.message)
            }
            result = fallback(journal.reportMissingCall(admission, source: source))
        }
        let phase: CallPhase = switch result {
        case .success: .returned
        case .failure: .threw
        }
        journal.complete(admission, phase: phase, origin: origin, replacing: InoutValues(before: before, after: .some(value)))
        return try result.get()
    }

    func verification(
        matching before: Matcher<Value>, after: Matcher<Value>?, phase: CallPhase, origin: CallOrigin?
    ) -> Verification<InoutValues<Value>> {
        let matcher = Matcher<InoutValues<Value>> { values in
            guard before.matches(values.before) else { return false }
            guard let after else { return true }
            guard let value = values.after else { return false }
            return after.matches(value)
        }
        return journal.verification(matching: matcher, phase: phase, origin: origin)
    }
}

public final class InoutSyncEndpoint<Value: Sendable, Output: Sendable>: Sendable {
    private let dispatch: InoutSyncDispatch<Value, Output, Never>

    public init(
        id: EndpointID, configuration: InoutSyncConfiguration<Value, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        forwarding: (@Sendable (inout Value) -> Output)? = nil,
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        let answer = forwarding.map { inoutSyncAnswer($0) }
        let recovery = fallback.map { fallback in
            { @Sendable (issue: MockIssue) in Result<Output, Never>.success(fallback(issue)) }
        }
        dispatch = InoutSyncDispatch(journal: Journal(endpoint: id, reporter: failureReporter, scope: scope),
                                     configuration: configuration, forwarding: answer, fallback: recovery)
    }

    public func invoke(_ value: inout Value, source: SourceLocation = SourceLocation()) -> Output {
        dispatch.invoke(&value, source: source)
    }

    /// The after matcher sees only completed values.
    public func verification(
        matching before: Matcher<Value>, after: Matcher<Value>? = nil,
        phase: CallPhase = .admitted, origin: CallOrigin? = nil
    ) -> Verification<InoutValues<Value>> {
        dispatch.verification(matching: before, after: after, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<InoutValues<Value>>] { dispatch.journal.snapshot().calls }
}

public final class InoutSyncThrowingEndpoint<Value: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let dispatch: InoutSyncDispatch<Value, Output, Failure>

    public init(
        id: EndpointID, configuration: InoutSyncThrowingConfiguration<Value, Output, Failure>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        forwarding: InoutSyncThrowingForwarding<Value, Output, Failure>? = nil,
        failureMapping: (@Sendable (MockIssue) -> Failure)? = nil
    ) {
        let recovery = failureMapping.map { mapping in
            { @Sendable (issue: MockIssue) in Result<Output, Failure>.failure(mapping(issue)) }
        }
        dispatch = InoutSyncDispatch(journal: Journal(endpoint: id, reporter: failureReporter, scope: scope),
                                     configuration: configuration, forwarding: forwarding?.answer, fallback: recovery)
    }

    public func invoke(_ value: inout Value, source: SourceLocation = SourceLocation()) throws(Failure) -> Output {
        try dispatch.invoke(&value, source: source)
    }

    /// The after matcher sees only completed values.
    public func verification(
        matching before: Matcher<Value>, after: Matcher<Value>? = nil,
        phase: CallPhase = .admitted, origin: CallOrigin? = nil
    ) -> Verification<InoutValues<Value>> {
        dispatch.verification(matching: before, after: after, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<InoutValues<Value>>] { dispatch.journal.snapshot().calls }
}

extension InoutSyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported UnexpectedInvocationError for an unstubbed ordinary throwing call.
    public convenience init(
        id: EndpointID, configuration: InoutSyncThrowingConfiguration<Value, Output, Failure>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        forwarding: InoutSyncThrowingForwarding<Value, Output, Failure>? = nil
    ) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  forwarding: forwarding, failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}
