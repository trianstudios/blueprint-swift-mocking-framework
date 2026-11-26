// The outer plan is Sendable and storable. Its callback parameter is nonescaping
// and is passed directly from the original synchronous invocation.
private typealias ScopedSyncCallbackAnswer<Input, CallbackInput, CallbackResult, Output> =
    @Sendable (Input, (CallbackInput) -> CallbackResult) -> Output

public struct SyncCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate let rules: [Rule<Input, ScopedSyncCallbackAnswer<Input, CallbackInput, CallbackResult, Output>>]
}

/// Builds immutable answer rules that match only the regular arguments.
public final class SyncCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    private let builder = EffectRulesBuilder<Input, ScopedSyncCallbackAnswer<Input, CallbackInput, CallbackResult, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> SyncCallbackStub<Input, CallbackInput, CallbackResult, Output> {
        SyncCallbackStub(owner: self, matcher: matcher)
    }

    fileprivate func add(
        _ matcher: Matcher<Input>,
        _ answer: @escaping @Sendable (Input, (CallbackInput) -> CallbackResult) -> Output
    ) {
        builder.add(matcher, answer)
    }

    public func finish() -> SyncCallbackConfiguration<Input, CallbackInput, CallbackResult, Output> {
        SyncCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let owner: SyncCallbackStubbing<Input, CallbackInput, CallbackResult, Output>
    fileprivate let matcher: Matcher<Input>

    public func willReturn(_ output: Output) { willAnswer { _, _ in output } }

    /// The answer may invoke the supplied callback only during the synchronous call.
    public func willAnswer(_ answer: @escaping @Sendable (Input, (CallbackInput) -> CallbackResult) -> Output) {
        owner.add(matcher, answer)
    }
}

/// A synchronous, nonthrowing endpoint with one nonescaping callback argument.
/// Matching and history contain only the regular arguments in Input.
public final class SyncCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private let configuration: SyncCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>
    private let journal: Journal<Input>
    private let forwarding: ScopedSyncCallbackAnswer<Input, CallbackInput, CallbackResult, Output>?
    private let fallback: (@Sendable (MockIssue) -> Output)?

    /// A matching stub takes precedence over forwarding. A missing or refused call
    /// reports an issue before returning the failure fallback, if one is supplied.
    public init(
        id: EndpointID, configuration: SyncCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        forwarding: (@Sendable (Input, (CallbackInput) -> CallbackResult) -> Output)? = nil,
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.forwarding = forwarding
        self.fallback = fallback
    }

    public func invoke(
        _ input: Input, _ callback: (CallbackInput) -> CallbackResult, source: SourceLocation = SourceLocation()
    ) -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        let stub = configuration.rules.reversed().first { $0.matcher.matches(input) }
        if let answer = stub?.answer ?? forwarding {
            let result = answer(input, callback)
            journal.complete(admission, phase: .returned, origin: stub == nil ? .forwarded : nil)
            return result
        }
        return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
    }

    public func verification(
        matching matcher: Matcher<Input>, phase: CallPhase = .admitted, origin: CallOrigin? = nil
    ) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}
