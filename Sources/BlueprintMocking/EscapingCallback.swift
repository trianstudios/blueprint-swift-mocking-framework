/// A retained callback can become unavailable after its session is reset or finished.
public enum CallbackDeliveryError: Error, Equatable, Sendable {
    case unavailable
}

private typealias NonisolatedCallback<Input, Output> = @Sendable (Input) -> Output
private typealias MainActorCallback<Input, Output> = @MainActor @Sendable (Input) -> Output

/// Retains the original function type, including any global actor, across session operations.
private final class CallbackCaptureStorage<Callback: Sendable>: SessionJournalRegistration {
    private struct Entry: Sendable {
        let invocation: SessionEvent
        let callback: Callback
    }

    let session: MockSession
    private let storage = CriticalState<[SessionInvocationID: Entry]>([:])

    init(session: MockSession) {
        self.session = session
        session.register(self)
    }

    var admissions: [SessionEvent] {
        let invocations = session.withLock { _ in storage.withLock { $0.values.map(\.invocation) } }
        return invocations.sorted { $0.ordinal < $1.ordinal }
    }

    func callback(for invocation: SessionEvent) -> Callback? {
        session.withLock { state -> Callback? in
            guard !state.isFinished, state.epoch == invocation.epoch else { return nil }
            return storage.withLock { $0[invocation.invocationID]?.callback }
        }
    }

    func publish(_ callback: Callback, recording invocation: SessionEvent) {
        session.withLock { state in
            guard !state.isFinished, state.epoch == invocation.epoch else { return }
            storage.withLock { $0[invocation.invocationID] = Entry(invocation: invocation, callback: callback) }
        }
        withExtendedLifetime(callback) {}
    }

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

private protocol CallbackCapturing<Callback>: AnyObject, Sendable {
    associatedtype Callback: Sendable
    var storage: CallbackCaptureStorage<Callback> { get }
}

private struct EscapingCallbackBehavior<Input: Sendable, Callback: Sendable, Output: Sendable>: Sendable {
    let captor: (any CallbackCapturing<Callback>)?
    let answer: @Sendable (Input) -> Output
}

private typealias EscapingCallbackRule<Input: Sendable, Callback: Sendable, Output: Sendable> =
    Rule<Input, EscapingCallbackBehavior<Input, Callback, Output>>

/// Selects a rule, publishes its capture, and keeps only ordinary arguments in the call journal.
private struct EscapingCallbackDispatch<Input: Sendable, Callback: Sendable, Output: Sendable>: Sendable {
    private let rules: [EscapingCallbackRule<Input, Callback, Output>]
    private let journal: Journal<Input>
    private let fallback: (@Sendable (MockIssue) -> Output)?

    init(
        id: EndpointID, rules: [EscapingCallbackRule<Input, Callback, Output>], failureReporter: FailureReporter,
        scope: MockScope, fallback: (@Sendable (MockIssue) -> Output)?
    ) {
        precondition(rules.allSatisfy {
            $0.answer.captor.map { $0.storage.session.id == scope.session.id } ?? true
        }, "Callback captor belongs to a different mock session")
        self.rules = rules
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.fallback = fallback
    }

    func invoke(_ input: Input, _ callback: Callback, source: SourceLocation) -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        guard let winner = rules.reversed().first(where: { $0.matcher.matches(input) }) else {
            return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
        }
        winner.answer.captor?.storage.publish(callback, recording: admission.event)
        let result = winner.answer.answer(input)
        journal.complete(admission, phase: .returned)
        return result
    }

    func verification(matching matcher: Matcher<Input>, phase: CallPhase) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }
}

/// A typed handle for a nonisolated Sendable callback captured by a winning stub.
/// The handle does not own the callback.
public struct EscapingCallbackCapture<Input: Sendable, Output: Sendable>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<NonisolatedCallback<Input, Output>>?

    /// Delivers synchronously on the caller. Reset and finish prevent new deliveries.
    /// A delivery that already acquired its closure can finish.
    public func invoke(_ input: Input) throws(CallbackDeliveryError) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw .unavailable }
        return callback(input)
    }
}

/// Keeps explicitly captured nonisolated Sendable callbacks until reset, finish, or deallocation.
public final class EscapingCallbackCaptor<Input: Sendable, Output: Sendable>: Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<NonisolatedCallback<Input, Output>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [EscapingCallbackCapture<Input, Output>] {
        storage.admissions.map { EscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate typealias Callback = NonisolatedCallback<CallbackInput, CallbackResult>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a synchronous method with a nonisolated Sendable callback.
public final class SyncEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate typealias Callback = NonisolatedCallback<CallbackInput, CallbackResult>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output> {
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

/// Journals ordinary arguments and retains callbacks only for an explicitly selected captor.
public final class SyncEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private typealias Callback = NonisolatedCallback<CallbackInput, CallbackResult>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID, configuration: SyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @Sendable (CallbackInput) -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, callback, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}

/// A typed handle for a MainActor-isolated Sendable callback captured by a winning stub.
/// The handle does not own the callback.
public struct MainActorEscapingCallbackCapture<Input: Sendable, Output: Sendable>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<MainActorCallback<Input, Output>>?

    /// Delivers synchronously on MainActor. Reset and finish prevent new deliveries.
    /// A delivery that already acquired its closure can finish.
    @MainActor
    public func invoke(_ input: Input) throws(CallbackDeliveryError) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw .unavailable }
        return callback(input)
    }
}

/// Keeps explicitly captured MainActor-isolated Sendable callbacks until reset, finish, or deallocation.
public final class MainActorEscapingCallbackCaptor<Input: Sendable, Output: Sendable>: Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<MainActorCallback<Input, Output>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [MainActorEscapingCallbackCapture<Input, Output>] {
        storage.admissions.map { MainActorEscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncMainActorEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate typealias Callback = MainActorCallback<CallbackInput, CallbackResult>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a synchronous method with a MainActor-isolated Sendable callback.
public final class SyncMainActorEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate typealias Callback = MainActorCallback<CallbackInput, CallbackResult>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncMainActorEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output> {
        SyncMainActorEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncMainActorEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output> {
        SyncMainActorEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncMainActorEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let owner: SyncMainActorEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: MainActorEscapingCallbackCaptor<CallbackInput, CallbackResult>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(into captor: MainActorEscapingCallbackCaptor<CallbackInput, CallbackResult>) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals ordinary arguments and retains callbacks only for an explicitly selected captor.
public final class SyncMainActorEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private typealias Callback = MainActorCallback<CallbackInput, CallbackResult>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID, configuration: SyncMainActorEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @MainActor @Sendable (CallbackInput) -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, callback, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}

// Keep typed-throwing function metadata out of generic storage on the original OS floors.
private typealias ThrowingCallback<Input, Output, Failure: Error> =
    @Sendable (Input) -> Result<Output, Failure>

/// A typed handle for a throwing callback captured by a winning stub.
public struct ThrowingEscapingCallbackCapture<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<ThrowingCallback<Input, Output, Failure>>?

    /// Delivers synchronously and propagates the callback's declared failure unchanged.
    /// The supplied mapping runs only if the handle can no longer deliver.
    public func invoke(_ input: Input, onUnavailable: () -> Failure) throws(Failure) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw onUnavailable() }
        return try callback(input).get()
    }
}

/// Retains an opted-in throwing callback until reset, finish, or deallocation.
public final class ThrowingEscapingCallbackCaptor<Input: Sendable, Output: Sendable, Failure: Error>:
    Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<ThrowingCallback<Input, Output, Failure>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [ThrowingEscapingCallbackCapture<Input, Output, Failure>] {
        storage.admissions.map { ThrowingEscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncThrowingEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
>: Sendable {
    fileprivate typealias Callback = ThrowingCallback<CallbackInput, CallbackResult, Failure>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a nonthrowing method with a typed-throwing callback.
public final class SyncThrowingEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
> {
    fileprivate typealias Callback = ThrowingCallback<CallbackInput, CallbackResult, Failure>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncThrowingEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output, Failure> {
        SyncThrowingEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncThrowingEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output, Failure> {
        SyncThrowingEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncThrowingEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
> {
    fileprivate let owner: SyncThrowingEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output, Failure>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: ThrowingEscapingCallbackCaptor<CallbackInput, CallbackResult, Failure>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(into captor: ThrowingEscapingCallbackCaptor<CallbackInput, CallbackResult, Failure>) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals the nonthrowing method and defers its callback's separate effect to replay.
public final class SyncThrowingEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
>: Sendable {
    private typealias Callback = ThrowingCallback<CallbackInput, CallbackResult, Failure>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID,
        configuration: SyncThrowingEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output, Failure>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @Sendable (CallbackInput) throws(Failure) -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, { value in
            do throws(Failure) { return .success(try callback(value)) }
            catch { return .failure(error) }
        }, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}

private typealias AsyncCallback<Input, Output> = @Sendable (Input) async -> Output

/// A typed handle for an asynchronous callback captured by a winning stub.
public struct AsyncEscapingCallbackCapture<Input: Sendable, Output: Sendable>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<AsyncCallback<Input, Output>>?

    /// Acquires the callback before suspension and runs it in the caller's task.
    /// Reset and finish refuse later acquisitions. A replay that already acquired its
    /// callback can finish, and the session does not track it as an active invocation.
    public func invoke(_ input: Input) async throws(CallbackDeliveryError) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw .unavailable }
        return await callback(input)
    }
}

/// Retains an opted-in async callback until reset, finish, or deallocation.
public final class AsyncEscapingCallbackCaptor<Input: Sendable, Output: Sendable>: Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<AsyncCallback<Input, Output>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [AsyncEscapingCallbackCapture<Input, Output>] {
        storage.admissions.map { AsyncEscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncAsyncEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate typealias Callback = AsyncCallback<CallbackInput, CallbackResult>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a synchronous nonthrowing method with an async callback.
public final class SyncAsyncEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate typealias Callback = AsyncCallback<CallbackInput, CallbackResult>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncAsyncEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output> {
        SyncAsyncEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncAsyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output> {
        SyncAsyncEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncAsyncEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let owner: SyncAsyncEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: AsyncEscapingCallbackCaptor<CallbackInput, CallbackResult>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(into captor: AsyncEscapingCallbackCaptor<CallbackInput, CallbackResult>) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals registration and retains the callback only for an explicitly selected captor.
public final class SyncAsyncEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private typealias Callback = AsyncCallback<CallbackInput, CallbackResult>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID, configuration: SyncAsyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @Sendable (CallbackInput) async -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, callback, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}

// Use the same checked Result representation as the other typed-throwing async endpoints.
private typealias AsyncThrowingCallback<Input, Output, Failure: Error> =
    @Sendable (Input) async -> Result<Output, Failure>

/// A typed handle for an async throwing callback captured by a winning stub.
public struct AsyncThrowingEscapingCallbackCapture<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<AsyncThrowingCallback<Input, Output, Failure>>?

    /// Acquires the callback before suspension and runs it in the caller's task.
    /// Reset and finish refuse later acquisitions. An acquired replay can still return
    /// or throw its original failure. The mapping runs only when acquisition fails.
    public func invoke(_ input: Input, onUnavailable: @Sendable () -> Failure) async throws(Failure) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw onUnavailable() }
        let result = await callback(input)
        return try result.get()
    }
}

/// Retains an opted-in async throwing callback until reset, finish, or deallocation.
public final class AsyncThrowingEscapingCallbackCaptor<Input: Sendable, Output: Sendable, Failure: Error>:
    Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<AsyncThrowingCallback<Input, Output, Failure>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [AsyncThrowingEscapingCallbackCapture<Input, Output, Failure>] {
        storage.admissions.map { AsyncThrowingEscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncAsyncThrowingEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
>: Sendable {
    fileprivate typealias Callback = AsyncThrowingCallback<CallbackInput, CallbackResult, Failure>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a synchronous nonthrowing method with an async throwing callback.
public final class SyncAsyncThrowingEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
> {
    fileprivate typealias Callback = AsyncThrowingCallback<CallbackInput, CallbackResult, Failure>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncAsyncThrowingEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output, Failure> {
        SyncAsyncThrowingEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncAsyncThrowingEscapingCallbackConfiguration<
        Input, CallbackInput, CallbackResult, Output, Failure
    > {
        SyncAsyncThrowingEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncAsyncThrowingEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
> {
    fileprivate let owner: SyncAsyncThrowingEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output, Failure>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: AsyncThrowingEscapingCallbackCaptor<CallbackInput, CallbackResult, Failure>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(
        into captor: AsyncThrowingEscapingCallbackCaptor<CallbackInput, CallbackResult, Failure>
    ) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals registration and defers the callback's asynchronous typed failure to replay.
public final class SyncAsyncThrowingEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable, Failure: Error
>: Sendable {
    private typealias Callback = AsyncThrowingCallback<CallbackInput, CallbackResult, Failure>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID,
        configuration: SyncAsyncThrowingEscapingCallbackConfiguration<
            Input, CallbackInput, CallbackResult, Output, Failure
        >,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @Sendable (CallbackInput) async throws(Failure) -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, { value in
            do throws(Failure) { return .success(try await callback(value)) }
            catch { return .failure(error) }
        }, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}

private typealias MainActorAsyncCallback<Input, Output> = @MainActor @Sendable (Input) async -> Output

/// A typed handle for a MainActor async callback captured by a winning stub.
public struct MainActorAsyncEscapingCallbackCapture<Input: Sendable, Output: Sendable>: Sendable {
    public let invocation: SessionEvent
    fileprivate weak var storage: CallbackCaptureStorage<MainActorAsyncCallback<Input, Output>>?

    /// Acquires the callback on MainActor before awaiting it in the caller's task.
    /// Reset and finish refuse later acquisitions. A replay that already acquired its
    /// callback can finish, and the session does not track it as an active invocation.
    @MainActor
    public func invoke(_ input: Input) async throws(CallbackDeliveryError) -> Output {
        guard let callback = storage?.callback(for: invocation) else { throw .unavailable }
        return await callback(input)
    }
}

/// Retains an opted-in MainActor async callback until reset, finish, or deallocation.
public final class MainActorAsyncEscapingCallbackCaptor<Input: Sendable, Output: Sendable>:
    Sendable, CallbackCapturing {
    fileprivate let storage: CallbackCaptureStorage<MainActorAsyncCallback<Input, Output>>

    public init(session: MockSession) {
        storage = CallbackCaptureStorage(session: session)
    }

    /// Returns handles ordered by the originating mock call's admission.
    public var captures: [MainActorAsyncEscapingCallbackCapture<Input, Output>] {
        storage.admissions.map { MainActorAsyncEscapingCallbackCapture(invocation: $0, storage: storage) }
    }
}

public struct SyncMainActorAsyncEscapingCallbackConfiguration<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    fileprivate typealias Callback = MainActorAsyncCallback<CallbackInput, CallbackResult>
    fileprivate let rules: [EscapingCallbackRule<Input, Callback, Output>]
}

/// Builds immutable rules for a synchronous nonthrowing method with a MainActor async callback.
public final class SyncMainActorAsyncEscapingCallbackStubbing<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate typealias Callback = MainActorAsyncCallback<CallbackInput, CallbackResult>
    fileprivate let builder = EffectRulesBuilder<Input, EscapingCallbackBehavior<Input, Callback, Output>>()

    public init() {}

    public func matching(
        _ matcher: Matcher<Input>
    ) -> SyncMainActorAsyncEscapingCallbackStub<Input, CallbackInput, CallbackResult, Output> {
        SyncMainActorAsyncEscapingCallbackStub(owner: self, matcher: matcher, captor: nil)
    }

    public func finish() -> SyncMainActorAsyncEscapingCallbackConfiguration<
        Input, CallbackInput, CallbackResult, Output
    > {
        SyncMainActorAsyncEscapingCallbackConfiguration(rules: builder.finish())
    }
}

public struct SyncMainActorAsyncEscapingCallbackStub<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
> {
    fileprivate let owner: SyncMainActorAsyncEscapingCallbackStubbing<Input, CallbackInput, CallbackResult, Output>
    fileprivate let matcher: Matcher<Input>
    fileprivate let captor: MainActorAsyncEscapingCallbackCaptor<CallbackInput, CallbackResult>?

    /// Captures only when this rule wins. The mock and captor must share a session.
    public func capturingCallback(into captor: MainActorAsyncEscapingCallbackCaptor<CallbackInput, CallbackResult>) -> Self {
        Self(owner: owner, matcher: matcher, captor: captor)
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.builder.add(matcher, EscapingCallbackBehavior(captor: captor, answer: answer))
    }
}

/// Journals nonisolated registration and preserves MainActor isolation on the retained callback.
public final class SyncMainActorAsyncEscapingCallbackEndpoint<
    Input: Sendable, CallbackInput: Sendable, CallbackResult: Sendable, Output: Sendable
>: Sendable {
    private typealias Callback = MainActorAsyncCallback<CallbackInput, CallbackResult>
    private let dispatch: EscapingCallbackDispatch<Input, Callback, Output>

    public init(
        id: EndpointID,
        configuration: SyncMainActorAsyncEscapingCallbackConfiguration<Input, CallbackInput, CallbackResult, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        dispatch = EscapingCallbackDispatch(id: id, rules: configuration.rules, failureReporter: failureReporter,
                                            scope: scope, fallback: fallback)
    }

    public func invoke(
        _ input: Input, _ callback: @escaping @MainActor @Sendable (CallbackInput) async -> CallbackResult,
        source: SourceLocation = SourceLocation()
    ) -> Output {
        dispatch.invoke(input, callback, source: source)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }
}
