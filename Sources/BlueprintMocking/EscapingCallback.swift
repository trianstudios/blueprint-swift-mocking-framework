/// A retained callback can become unavailable after its session is reset or finished.
public enum CallbackDeliveryError: Error, Equatable, Sendable {
    case unavailable
}

/// A typed handle for a callback captured by a winning stub. It does not own the callback.
public struct EscapingCallbackCapture<Input: Sendable, Output: Sendable>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var captor: EscapingCallbackCaptor<Input, Output>?

    /// Delivers synchronously on the caller. Reset and finish prevent new deliveries.
    /// A delivery already admitted before either operation can finish.
    public func invoke(_ input: Input) throws(CallbackDeliveryError) -> Output {
        guard let callback = captor?.callback(for: invocation) else { throw .unavailable }
        return callback(input)
    }
}

/// Keeps explicitly captured, nonisolated Sendable callbacks until reset, finish, or deallocation.
public final class EscapingCallbackCaptor<Input: Sendable, Output: Sendable>: Sendable {
    fileprivate typealias Callback = @Sendable (Input) -> Output

    private struct Entry: Sendable {
        let invocation: SessionEvent
        let callback: Callback
    }

    fileprivate let session: MockSession
    private let storage = CriticalState<[SessionInvocationID: Entry]>([:])

    public init(session: MockSession) {
        self.session = session
        session.register(self)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [EscapingCallbackCapture<Input, Output>] {
        let invocations = session.withLock { _ in storage.withLock { $0.values.map(\.invocation) } }
        return invocations.sorted { $0.ordinal < $1.ordinal }
            .map { EscapingCallbackCapture(invocation: $0, captor: self) }
    }

    fileprivate func callback(for invocation: SessionEvent) -> Callback? {
        session.withLock { state -> Callback? in
            guard !state.isFinished, state.epoch == invocation.epoch else { return nil }
            return storage.withLock { $0[invocation.invocationID]?.callback }
        }
    }

    fileprivate func publish(_ callback: @escaping Callback, recording invocation: SessionEvent) {
        session.withLock { state in
            guard !state.isFinished, state.epoch == invocation.epoch else { return }
            storage.withLock { $0[invocation.invocationID] = Entry(invocation: invocation, callback: callback) }
        }
        withExtendedLifetime(callback) {}
    }
}

extension EscapingCallbackCaptor: SessionJournalRegistration {
    func discardHistory() -> any Sendable {
        storage.withLock {
            let retired = $0
            $0 = [:]
            return retired
        }
    }

    func discardCapturesOnFinish() -> (any Sendable)? {
        discardHistory()
    }
}

private struct EscapingCallbackBehavior<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    let captor: EscapingCallbackCaptor<CallbackInput, CallbackResult>?
    let answer: @Sendable (Input) -> Output
}

public struct SyncEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate let rules: [Rule<Input, EscapingCallbackBehavior<Input, CallbackInput, CallbackResult, Output>>]
}

/// Builds immutable rules for a synchronous method with an escaping Sendable callback.
public final class SyncEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let builder = EffectRulesBuilder<
        Input, EscapingCallbackBehavior<Input, CallbackInput, CallbackResult, Output>
    >()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> SyncEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output> {
        SyncEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output> {
        SyncEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let owner: SyncEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: EscapingCallbackCaptor<CallbackInput, CallbackResult>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(into captor: EscapingCallbackCaptor<CallbackInput, CallbackResult>) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals ordinary arguments. Only an explicitly selected captor can retain the callback.
public final class SyncEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private let configuration: SyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>
    private let journal: Journal<Input>
    private let fallback: (@Sendable (MockIssue) -> Output)?

    public init(
        id: EndpointID, configuration: SyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        precondition(configuration.rules.allSatisfy {
            $0.answer.captor.map { $0.session.id == scope.session.id } ?? true
        }, "Callback captor belongs to a different mock session")
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.fallback = fallback
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @Sendable (CallbackInput) -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        guard let winner = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) else {
            return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
        }
        winner.answer.captor?.publish(callback, recording: admission.event)
        let result = winner.answer.answer(input)
        journal.complete(admission, phase: .returned)
        return result
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }
}
