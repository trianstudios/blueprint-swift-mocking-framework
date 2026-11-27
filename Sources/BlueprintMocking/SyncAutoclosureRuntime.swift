/// A checked, immutable plan for a synchronous method with a lazy autoclosure.
public struct SyncAutoclosureConfiguration<Input: Sendable, Value: Sendable, Output: Sendable>: Sendable {
    fileprivate let callback: SyncCallbackConfiguration<Input, Void, Value, Output>
}

/// Matches ordinary arguments. Only a selected answer can request an evaluation.
public final class SyncAutoclosureStubbing<Input: Sendable, Value: Sendable, Output: Sendable> {
    private let callback = SyncCallbackStubbing<Input, Void, Value, Output>()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> SyncAutoclosureStub<Input, Value, Output> {
        SyncAutoclosureStub(callback: callback.matching(matcher))
    }

    public func finish() -> SyncAutoclosureConfiguration<Input, Value, Output> {
        SyncAutoclosureConfiguration(callback: callback.finish())
    }
}

public struct SyncAutoclosureStub<Input: Sendable, Value: Sendable, Output: Sendable> {
    fileprivate let callback: SyncCallbackStub<Input, Void, Value, Output>

    public func willReturn(_ output: Output) { callback.willReturn(output) }

    /// The supplied evaluation function is nonescaping. Every explicit call evaluates
    /// the original expression once. Matching and verification do not evaluate it.
    public func willAnswer(_ answer: @escaping @Sendable (Input, () -> Value) -> Output) {
        callback.willAnswer { input, thunk in
            answer(input) { thunk(()) }
        }
    }
}

/// Holds only ordinary invocation metadata. An autoclosure is never retained.
public final class SyncAutoclosureEndpoint<Input: Sendable, Value: Sendable, Output: Sendable>: Sendable {
    private let callback: SyncCallbackEndpoint<Input, Void, Value, Output>

    public init(
        id: EndpointID, configuration: SyncAutoclosureConfiguration<Input, Value, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        callback = SyncCallbackEndpoint(id: id, configuration: configuration.callback,
                                        failureReporter: failureReporter, scope: scope, fallback: fallback)
    }

    public func invoke(_ input: Input, _ evaluate: () -> Value, source: SourceLocation = SourceLocation()) -> Output {
        callback.invoke(input, { _ in evaluate() }, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        callback.verification(matching: matcher, phase: phase)
    }

    public var invocations: [Invocation<Input>] { callback.invocations }
}
