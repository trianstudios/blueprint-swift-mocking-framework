import Foundation

/// Identifies one explicit session independently of its mocks and history resets.
public struct SessionID: Hashable, Sendable {
    public let rawValue: UUID
}

/// Identifies a history generation within a session.
public struct SessionEpoch: Hashable, Sendable {
    public let sessionID: SessionID
    public let rawValue: UInt64
}

/// A stable mock identity that may group several endpoints.
public struct MockID: Hashable, Sendable {
    public let sessionID: SessionID
    public let rawValue: UInt64
}

/// Shared by all events from one invocation.
public struct SessionInvocationID: Hashable, Sendable {
    public let sessionID: SessionID
    public let rawValue: UInt64
}

enum ScopeAdmissionRejection: Sendable {
    case finished
    case staleTypeScope

    func message(for endpoint: EndpointID) -> String {
        switch self {
        case .finished:
            "Cannot call \(endpoint.diagnosticName) in a finished mock session"
        case .staleTypeScope:
            "Cannot call \(endpoint.diagnosticName) with a stale type-level mock scope"
        }
    }
}

/// An explicit answer or a request to invoke the real generic dependency.
public enum GenericSpyDecision<Output: Sendable>: Sendable {
    case handled(Output)
    case forward
}

/// An admitted infallible construction awaiting a fully initialized instance.
/// Dropping an uncompleted attempt records a terminated outcome.
public struct MockConstructionAttempt: ~Copyable, Sendable {
    public let instanceScope: MockScope
    fileprivate let invocation: SessionInvocationID

    fileprivate var isCompleted = false
    fileprivate var publishesInstanceLink = false

    /// Records cancellation requested while async preparation runs without changing its result.
    public borrowing func observingCancellation<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async -> Value
    ) async -> Value {
        await instanceScope.observingConstructionCancellation(for: invocation, isolation: isolation, operation)
    }

    /// Generated initializer witnesses call this after initializing all stored state.
    public consuming func complete() {
        var attempt = consume self
        attempt.isCompleted = true
        attempt.instanceScope.completeProviderInvocation(
            attempt.invocation, phase: .returned,
            constructedMockID: attempt.publishesInstanceLink ? attempt.instanceScope.id : nil
        )
    }

    deinit {
        if !isCompleted {
            instanceScope.completeProviderInvocation(invocation, phase: .terminated)
        }
    }
}

/// An admitted typed-throwing construction with no allocated instance identity.
public struct MockThrowingConstructionAttempt: ~Copyable, Sendable {
    fileprivate let scope: MockScope
    fileprivate let invocation: SessionInvocationID
    fileprivate var isResolved = false

    /// Called after successful preparation. The instance is linked only when its initializer completes.
    public consuming func reserveInstance() -> MockConstructionAttempt {
        var attempt = consume self
        attempt.isResolved = true
        return MockConstructionAttempt(instanceScope: attempt.scope.session.makeMock(), invocation: attempt.invocation,
                                       publishesInstanceLink: true)
    }

    /// Records a request made while async preparation is active and returns the operation's result.
    public borrowing func observingCancellation<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async -> Value
    ) async -> Value {
        await scope.observingConstructionCancellation(for: invocation, isolation: isolation, operation)
    }

    /// Records the configured failure without allocating a mock identity.
    public consuming func recordFailure() {
        finishWithoutInstance(phase: .threw)
    }

    fileprivate consuming func finishWithoutInstance(phase: CallPhase) {
        var attempt = consume self
        attempt.isResolved = true
        attempt.scope.completeProviderInvocation(attempt.invocation, phase: phase)
    }

    deinit {
        if !isResolved { scope.completeProviderInvocation(invocation, phase: .terminated) }
    }
}

/// Explicit preparation result for a failable initializer.
public enum FailableConstructionDecision: Sendable {
    case initialize
    case returnNil
}

/// An admitted failable construction awaiting its configured decision.
public struct MockFailableConstructionAttempt: ~Copyable, Sendable {
    fileprivate let preparation: MockThrowingConstructionAttempt

    /// Records cancellation during async preparation without changing its failable result.
    public borrowing func observingCancellation<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async -> Value
    ) async -> Value {
        await preparation.observingCancellation(isolation: isolation, operation)
    }

    /// Reserves an identity after a decision to initialize. Completion publishes the instance link.
    public consuming func reserveInstance() -> MockConstructionAttempt {
        preparation.reserveInstance()
    }

    /// Completes the configured nil result without allocating an instance identity.
    public consuming func recordNil() {
        preparation.finishWithoutInstance(phase: .returned)
    }
}

/// The explicitly selected session and identity for a mock's endpoints.
public struct MockScope: Sendable {
    public let id: MockID
    public let session: MockSession
    let expectedEpoch: SessionEpoch?

    init(id: MockID, session: MockSession, expectedEpoch: SessionEpoch? = nil) {
        self.id = id
        self.session = session
        self.expectedEpoch = expectedEpoch
    }

    func admissionRejection(in state: MockSession.State) -> ScopeAdmissionRejection? {
        if let expectedEpoch, expectedEpoch != state.epoch { return .staleTypeScope }
        return state.isFinished ? .finished : nil
    }

    /// Generated value witnesses record an unlisted specialization before applying the missing-value policy.
    public func terminateMissingSpecialization<Argument>(
        of declaration: String, for type: Argument.Type, reporter: FailureReporter, source: SourceLocation
    ) -> Never {
        let endpoint = EndpointID(declaration, specializedFor: type)
        let (admission, rejection, delivery, wake, closedEpoch) = session.withLock {
            state -> (SessionEvent?, ScopeAdmissionRejection?, SessionQuiescenceDelivery?,
                      SessionObservationDelivery?, SessionEpoch?) in
            if let rejection = admissionRejection(in: state) {
                return (nil, rejection, nil, nil, state.isFinished ? state.epoch : nil)
            }
            let admission = state.admit(mockID: id, endpoint: endpoint,
                                        configurationRevision: RuleRevision(rawValue: 0))
            let (_, delivery) = state.complete(admission.invocationID, phase: .terminated)
            return (admission, nil, delivery, state.observationWake(), nil)
        }
        delivery?.publish()
        wake?.publish()
        let message = rejection?.message(for: endpoint)
            ?? "No configured specialization for \(endpoint.diagnosticName)"
        terminateRejectedValueCall(endpoint, message: message, reporter: reporter, source: source,
                             watermark: admission?.ordinal ?? 0, closedEpoch: closedEpoch)
    }

    private enum ProviderAdmission: Sendable {
        case accepted(SessionEvent, SessionObservationDelivery?)
        case rejected(ScopeAdmissionRejection, closedEpoch: SessionEpoch?)
    }

    /// Reserves a new instance identity and admits its infallible constructor atomically.
    public func beginInfallibleConstruction(
        of endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation
    ) -> MockConstructionAttempt {
        let event = admitProviderInvocation(endpoint, reporter: reporter, source: source, reservesInstance: true)
        return MockConstructionAttempt(instanceScope: MockScope(id: event.mockID, session: session),
                                       invocation: event.invocationID)
    }

    /// Admits a typed-throwing constructor under its construction scope's identity.
    public func beginThrowingConstruction(
        of endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation
    ) -> MockThrowingConstructionAttempt {
        let event = admitProviderInvocation(endpoint, reporter: reporter, source: source)
        return MockThrowingConstructionAttempt(scope: self, invocation: event.invocationID)
    }

    /// Admits an ordinary throwing constructor or reports and throws an unexpected invocation.
    public func beginOrdinaryThrowingConstruction(
        of endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation
    ) throws -> MockThrowingConstructionAttempt {
        switch claimProviderInvocation(endpoint) {
        case .accepted(let admission, let wake):
            wake?.publish()
            return MockThrowingConstructionAttempt(scope: self, invocation: admission.invocationID)
        case .rejected(let rejection, let closedEpoch):
            let issue = reportRejectedValueCall(endpoint, message: rejection.message(for: endpoint), reporter: reporter,
                                                source: source, watermark: 0, closedEpoch: closedEpoch,
                                                terminating: false)
            throw UnexpectedInvocationError(issue: issue)
        }
    }

    /// Admits async construction and reserves an identity without publishing an instance link.
    /// The generated witness completes the attempt after async setup and Swift initialization.
    public func beginAsyncConstruction(
        of endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation
    ) -> MockConstructionAttempt {
        beginThrowingConstruction(of: endpoint, reporter: reporter, source: source).reserveInstance()
    }

    /// Admits a failable constructor under its construction scope's identity.
    public func beginFailableConstruction(
        of endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation
    ) -> MockFailableConstructionAttempt {
        MockFailableConstructionAttempt(
            preparation: beginThrowingConstruction(of: endpoint, reporter: reporter, source: source)
        )
    }

    /// Records an immediate generic provider call without retaining its values.
    public func invokeGenericProvider<Argument: Sendable>(
        of declaration: String, for type: Argument.Type, reporter: FailureReporter, source: SourceLocation,
        _ answer: () -> Argument
    ) -> Argument {
        invokeProvider(EndpointID(declaration, specializedFor: type), reporter: reporter, source: source, answer)
    }

    /// Invokes a typed generic selection and forwards a declined call to the real dependency.
    public func invokeAsyncGenericSpy<Key: Sendable, Output: Sendable>(
        of declaration: String, for type: Key.Type, reporter: FailureReporter, source: SourceLocation,
        select: @Sendable () async -> GenericSpyDecision<Output>,
        forwarding: @Sendable () async -> Output
    ) async -> Output {
        let endpoint = EndpointID(declaration, specializedFor: type)
        let invocation = admitProviderInvocation(endpoint, reporter: reporter, source: source).invocationID
        switch await select() {
        case .handled(let result):
            completeProviderInvocation(invocation, phase: .returned)
            return result
        case .forward:
            let result = await forwarding()
            completeProviderInvocation(invocation, phase: .returned, origin: .forwarded)
            return result
        }
    }

    /// Records a nonescaping pack provider call with ordered type metadata and no retained values.
    public func invokePackProvider<Output: Sendable>(
        of declaration: String, types: [Any.Type], reporter: FailureReporter, source: SourceLocation,
        _ answer: () -> Output
    ) -> Output {
        invokeProvider(EndpointID(declaration, specializedForPack: types), reporter: reporter, source: source, answer)
    }

    /// Executes a nonescaping rethrows provider and records the terminal outcome.
    public func invokeRethrowsProvider<Output: Sendable>(
        of declaration: String, reporter: FailureReporter, source: SourceLocation,
        _ answer: () throws -> Output
    ) rethrows -> Output {
        try invokeProvider(EndpointID(declaration), reporter: reporter, source: source, answer)
    }

    /// Executes an async rethrows provider. The callback can suspend outside the session lock.
    public func invokeAsyncRethrowsProvider<Output: Sendable>(
        of declaration: String, reporter: FailureReporter, source: SourceLocation,
        _ answer: @Sendable () async throws -> Output
    ) async rethrows -> Output {
        let invocation = admitProviderInvocation(EndpointID(declaration), reporter: reporter, source: source).invocationID
        var phase = CallPhase.threw
        defer { completeProviderInvocation(invocation, phase: phase) }
        let result = try await answer()
        phase = .returned
        return result
    }

    private func invokeProvider<Output: Sendable>(
        _ endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation,
        _ answer: () throws -> Output
    ) rethrows -> Output {
        let invocation = admitProviderInvocation(endpoint, reporter: reporter, source: source).invocationID
        var phase = CallPhase.threw
        defer { completeProviderInvocation(invocation, phase: phase) }
        let result = try answer()
        phase = .returned
        return result
    }

    private func claimProviderInvocation(
        _ endpoint: EndpointID, reservesInstance: Bool = false
    ) -> ProviderAdmission {
        session.withLock { state -> ProviderAdmission in
            if let rejection = admissionRejection(in: state) {
                return .rejected(rejection, closedEpoch: state.isFinished ? state.epoch : nil)
            }
            let admittedMockID = reservesInstance ? state.makeMockID() : id
            let admission = state.admit(mockID: admittedMockID, endpoint: endpoint,
                                        configurationRevision: RuleRevision(rawValue: 0))
            return .accepted(admission, state.observationWake())
        }
    }

    private func admitProviderInvocation(
        _ endpoint: EndpointID, reporter: FailureReporter, source: SourceLocation, reservesInstance: Bool = false
    ) -> SessionEvent {
        switch claimProviderInvocation(endpoint, reservesInstance: reservesInstance) {
        case .rejected(let rejection, let closedEpoch):
            terminateRejectedValueCall(endpoint, message: rejection.message(for: endpoint), reporter: reporter,
                                       source: source, watermark: 0, closedEpoch: closedEpoch)
        case .accepted(let admission, let wake):
            wake?.publish()
            return admission
        }
    }

    fileprivate func observingConstructionCancellation<Value: Sendable>(
        for invocation: SessionInvocationID, isolation: isolated (any Actor)?,
        _ operation: () async -> Value
    ) async -> Value {
        let session = self.session
        return await withTaskCancellationHandler(operation: operation, onCancel: {
            let wake = session.withLock { $0.recordCancellationRequest(for: invocation) }
            wake?.publish()
        }, isolation: isolation)
    }

    fileprivate func completeProviderInvocation(
        _ invocation: SessionInvocationID, phase: CallPhase, origin: CallOrigin? = nil,
        constructedMockID: MockID? = nil
    ) {
        let (delivery, wake) = session.withLock { state in
            let (_, delivery) = state.complete(invocation, phase: phase, origin: origin,
                                               constructedMockID: constructedMockID)
            return (delivery, state.observationWake())
        }
        delivery?.publish()
        wake?.publish()
    }

    private func terminateRejectedValueCall(
        _ endpoint: EndpointID, message: String, reporter: FailureReporter, source: SourceLocation,
        watermark: UInt64, closedEpoch: SessionEpoch?
    ) -> Never {
        let issue = reportRejectedValueCall(endpoint, message: message, reporter: reporter, source: source,
                                            watermark: watermark, closedEpoch: closedEpoch, terminating: true)
        fatalError(issue.message)
    }

    private func reportRejectedValueCall(
        _ endpoint: EndpointID, message: String, reporter: FailureReporter, source: SourceLocation,
        watermark: UInt64, closedEpoch: SessionEpoch?, terminating: Bool
    ) -> MockIssue {
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint, message: message,
                              source: source, watermark: watermark)
        if !bufferOrphan(issue, closedEpoch: closedEpoch, terminating: terminating) {
            reporter.report(issue)
        }
        return issue
    }
}

/// Metadata about an admission or terminal outcome. Arguments remain in the endpoint's typed history.
public struct SessionEvent: Equatable, Sendable {
    public let ordinal: UInt64
    /// Monotonic elapsed time sampled when this event was committed.
    public let elapsed: Duration
    public let epoch: SessionEpoch
    public let mockID: MockID
    public let endpoint: EndpointID
    public let invocationID: SessionInvocationID
    public let configurationRevision: RuleRevision
    public let phase: CallPhase
    /// The forwarding origin for a terminal event. Admissions have no origin.
    public let origin: CallOrigin?

    // Mock numbers are allocated from 1; zero indicates that no attachment was published.
    fileprivate var constructedMockNumber: UInt64 = 0

    /// The instance attached by a successful constructor when it differs from the admission scope.
    public var constructedMockID: MockID? {
        guard constructedMockNumber != 0 else { return nil }
        return MockID(sessionID: epoch.sessionID, rawValue: constructedMockNumber)
    }
}

/// A cancellation request observed while an async invocation was active.
public struct SessionCancellationRequest: Equatable, Sendable {
    public let ordinal: UInt64
    public let elapsed: Duration
    public let admission: SessionEvent
}

/// A copy of one epoch's metadata as of a session-wide event watermark.
public struct SessionSnapshot: Equatable, Sendable {
    public let sessionID: SessionID
    public let epoch: SessionEpoch
    public let events: [SessionEvent]
    /// Requests are separate from admissions and terminal events.
    public let cancellationRequests: [SessionCancellationRequest]
    /// Highest request ordinal removed from this epoch, or nil when none were removed.
    public let cancellationRequestsPrunedThrough: UInt64?
    public let activeInvocationCount: Int
    public let watermark: UInt64
    /// Highest event ordinal removed from this epoch, or nil when none were removed.
    public let prunedThrough: UInt64?
    public let isFinished: Bool
}

public enum SessionResetMode: Sendable {
    /// Discard all history after every session invocation has completed.
    case requireQuiescence
    /// Retain earlier metadata so active invocations can finish in their original epochs.
    case detachActive
}

public enum SessionResetError: Error, Equatable, Sendable {
    case activeInvocations(count: Int)
    case finished
}

public enum SessionFinishError: Error, Equatable, Sendable {
    case activeInvocations(count: Int)
}

/// Clears typed history under the session gate. Retired values must be returned so their
/// destructors can only run after the caller releases the session and journal locks.
protocol SessionJournalRegistration: AnyObject, Sendable {
    func discardHistory(restartingSequences: Bool) -> any Sendable
    func discardCapturesOnFinish() -> (any Sendable)?
}

extension SessionJournalRegistration {
    func discardCapturesOnFinish() -> (any Sendable)? { nil }
}

private struct WeakSessionJournal: Sendable {
    weak var value: (any SessionJournalRegistration)?
}

private struct SessionRetirement: Sendable {
    let epoch: SessionEpoch
    // Even an upgraded weak reference may be the last owner of a registered journal.
    let journals: [any SessionJournalRegistration]
    let history: [any Sendable]
}

/// Coordinates metadata, admission order and history epochs across an explicit set of mocks.
public final class MockSession: Sendable {
    public let id: SessionID
    let orphanFailures: OrphanFailureBuffer?
    private let state: CriticalState<State>

    public convenience init() {
        self.init(clock: .continuous)
    }

    public convenience init(clock: SessionClockMode) {
        self.init(clock: clock, orphanFailures: nil)
    }

    public convenience init(orphanFailures: OrphanFailureBuffer) {
        self.init(clock: .continuous, orphanFailures: orphanFailures)
    }

    public init(clock: SessionClockMode, orphanFailures: OrphanFailureBuffer?) {
        let id = SessionID(rawValue: UUID())
        self.id = id
        self.orphanFailures = orphanFailures
        state = CriticalState(State(sessionID: id, clock: SessionClockState(clock)))
    }

    deinit {
        let pending = state.withLock { $0.retirePendingCallbacks() }
        for request in pending { request.retire(because: .unavailable) }
    }

    public func makeMock() -> MockScope {
        let mockID = state.withLock { $0.makeMockID() }
        return MockScope(id: mockID, session: self)
    }

    /// Creates a scope whose admissions and verification remain bound to this epoch.
    /// A history reset invalidates the scope even while the owning session stays open.
    public func makeEpochBoundMock() -> MockScope {
        let (mockID, epoch) = state.withLock { state in (state.makeMockID(), state.epoch) }
        return MockScope(id: mockID, session: self, expectedEpoch: epoch)
    }

    public func snapshot() -> SessionSnapshot {
        state.withLock { $0.snapshot(epoch: $0.epoch)! }
    }

    /// Moves a manual session clock forward without adding an event. The session acquires due
    /// callback deliveries at the new clock reading and runs them before this call returns.
    /// Due async steps resume on their own tasks.
    public func advanceClock(by duration: Duration) throws(SessionClockError) {
        let (wake, replacements, callbacks, delayedAnswers) = try state.withLock {
            (state: inout State) throws(SessionClockError) in
            try state.advanceClock(by: duration)
            return (state.observationWake(), state.resolveQuiescentReplacements(publishAtIdle: false),
                    state.acquireDueCallbacks(), state.acquireDueDelayedAnswers())
        }
        for replacement in replacements { replacement.publish() }
        wake?.publish()
        for answer in delayedAnswers { answer.publish() }
        callbacks.publish()
    }

    func removeScheduledCallbacks(id: ScheduledCallbackID) -> [PendingCallbackDelivery] {
        let removed = state.withLock { $0.removeScheduledCallbacks(id: id) }
        for request in removed { request.timer?.cancel() }
        return removed
    }

    func armNextContinuousCallback(id: ScheduledCallbackID) {
        state.withLock { $0.armNextContinuousCallback(id: id, owner: self) }
    }

    private func makeScheduledCallbackTimer(
        id: ScheduledCallbackID, occurrence: Int, until deadline: ContinuousClock.Instant
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline, tolerance: .zero)
                try Task.checkCancellation()
            } catch {
                return
            }
            self?.deliverScheduledCallback(id: id, occurrence: occurrence)
        }
    }

    private func deliverScheduledCallback(id: ScheduledCallbackID, occurrence: Int) {
        let delivery = state.withLock { $0.acquireContinuousCallback(id: id, occurrence: occurrence) }
        guard let acquired = delivery else { return }
        acquired.publish()
        armNextContinuousCallback(id: id)
    }

    func timedSnapshot() -> (snapshot: SessionSnapshot, elapsed: Duration) {
        state.withLock { $0.timedSnapshot() }
    }

    func continuousInstant(at elapsed: Duration) -> ContinuousClock.Instant? {
        state.withLock { $0.continuousInstant(at: elapsed) }
    }

    /// Returns nil for a foreign epoch or an epoch discarded by a destructive reset.
    public func snapshot(epoch: SessionEpoch) -> SessionSnapshot? {
        state.withLock { $0.snapshot(epoch: epoch) }
    }

    /// Starts a new epoch with the same rules, revision, and reserved sequence positions.
    /// Detached calls keep their original cursors and the earlier epoch retains its event metadata.
    /// Typed argument history is discarded and invocation identities stay unique.
    @discardableResult
    public func resetHistory(_ mode: SessionResetMode = .requireQuiescence)
        throws(SessionResetError) -> SessionEpoch {
        try reset(mode, restartingSequences: false)
    }

    /// Starts a new history epoch and rewinds its configured answer sequences.
    /// Detached invocations keep the sequence positions of their original epoch.
    @discardableResult
    public func resetHistoryAndSequences(_ mode: SessionResetMode = .requireQuiescence)
        throws(SessionResetError) -> SessionEpoch {
        try reset(mode, restartingSequences: true)
    }

    private func reset(_ mode: SessionResetMode, restartingSequences: Bool)
        throws(SessionResetError) -> SessionEpoch {
        let (retirement, wake, replacements, callbacks) = try state.withLock {
            (state: inout State) throws(SessionResetError) in
            let retirement = try state.resetHistory(mode, restartingSequences: restartingSequences)
            return (retirement, state.closeObservations(), state.resolveQuiescentReplacements(publishAtIdle: false),
                    state.retirePendingCallbacks())
        }
        for callback in callbacks { callback.retire(because: .unavailable) }
        for replacement in replacements { replacement.publish() }
        wake?.publish()
        // User destructors and last-owner journal destruction may reenter this session.
        withExtendedLifetime(retirement) {}
        return retirement.epoch
    }

    /// Closes admission at zero active calls across all epochs and preserves the final metadata.
    /// Repeated calls return the same final snapshot. The caller owns teardown of its tasks.
    @discardableResult
    public func finishIfQuiescent() throws(SessionFinishError) -> SessionSnapshot {
        let (snapshot, wake, retirement, callbacks) = try state.withLock {
            (state: inout State) throws(SessionFinishError) in
            let (snapshot, retirement) = try state.finishIfQuiescent()
            return (snapshot, state.closeObservations(), retirement, state.retirePendingCallbacks())
        }
        for callback in callbacks { callback.retire(because: .finished) }
        wake?.publish()
        withExtendedLifetime(retirement) {}
        return snapshot
    }

    func register(_ journal: any SessionJournalRegistration) {
        state.withLock { $0.register(journal) }
    }

    /// Internal session gate. Endpoint transactions acquire this before a typed journal lock.
    /// No user matcher, answer, reporter, or payload destruction may run inside the gate.
    func withLock<Result: Sendable, Failure: Error>(
        _ operation: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try state.withLock(operation)
    }

    struct State: Sendable {
        private struct EpochHistory: Sendable {
            var events: [SessionEvent] = []
            var cancellationRequests: [SessionCancellationRequest] = []
            var cancellationRequestsPrunedThrough: UInt64?
            var activeInvocationCount = 0
            var prunedThrough: UInt64?
        }

        private(set) var epoch: SessionEpoch
        private var clock: SessionClockState
        private var finishedElapsed: Duration?
        private var pendingCallbacks: [PendingCallbackDelivery] = []

        var isFinished: Bool { finishedElapsed != nil }

        private var nextMockNumber: UInt64 = 0
        private var nextInvocationNumber: UInt64 = 0
        private var lastEventOrdinal: UInt64 = 0
        private var histories: [SessionEpoch: EpochHistory]
        private var claimsByScope: [String: SessionConsumptionClaims] = [:]
        private var active: [SessionInvocationID: SessionEvent] = [:]
        private var activeCancellationRequests: Set<SessionInvocationID> = []
        // A wait belongs to an admitted call and survives a reset that detaches that call.
        private var delayedAnswers: [SessionInvocationID: PendingDelayedAnswer] = [:]
        var delayedAnswerWaiterCount: Int { delayedAnswers.count }
        var activeInvocationCountAcrossEpochs: Int { active.count }
        private var journals: [WeakSessionJournal] = []
        private var nextQuiescenceWaiter: UInt64 = 0
        private var quiescenceWaiters: [UInt64: SessionQuiescenceContinuation] = [:]
        private var quiescentReplacements: [QuiescentReplacement] = []
        private var nextObservationID: UInt64 = 0
        private var observations: [UInt64: SessionObservationContinuation] = [:]

        var observationCount: Int { observations.count }

        var quiescenceWaiterCount: Int { quiescenceWaiters.count }

        var quiescentReplacementCount: Int { quiescentReplacements.count }

        fileprivate init(sessionID: SessionID, clock: SessionClockState) {
            self.clock = clock
            let initialEpoch = SessionEpoch(sessionID: sessionID, rawValue: 0)
            epoch = initialEpoch
            histories = [initialEpoch: EpochHistory()]
        }

        fileprivate mutating func makeMockID() -> MockID {
            nextMockNumber += 1
            return MockID(sessionID: epoch.sessionID, rawValue: nextMockNumber)
        }

        fileprivate func snapshot(epoch: SessionEpoch) -> SessionSnapshot? {
            guard let history = histories[epoch] else { return nil }
            return SessionSnapshot(
                sessionID: epoch.sessionID, epoch: epoch,
                events: history.events, cancellationRequests: history.cancellationRequests,
                cancellationRequestsPrunedThrough: history.cancellationRequestsPrunedThrough,
                activeInvocationCount: history.activeInvocationCount, watermark: lastEventOrdinal,
                prunedThrough: history.prunedThrough, isFinished: isFinished
            )
        }

        func timedSnapshot() -> (snapshot: SessionSnapshot, elapsed: Duration) {
            (snapshot(epoch: epoch)!, finishedElapsed ?? clock.elapsed)
        }

        // Projected publications share the session ordering, but carry no public
        // metadata event. Metadata replay already permits these ordinal gaps.
        mutating func recordProjectionPosition() -> (ordinal: UInt64, elapsed: Duration) {
            lastEventOrdinal += 1
            return (lastEventOrdinal, clock.elapsed)
        }

        fileprivate func continuousInstant(at elapsed: Duration) -> ContinuousClock.Instant? {
            clock.continuousInstant(at: elapsed)
        }

        fileprivate mutating func advanceClock(by duration: Duration) throws(SessionClockError) {
            try clock.advance(by: duration)
        }

        mutating func scheduleCallbacks(
            id: ScheduledCallbackID, occurrences: [ScheduledCallbackOccurrence]
        ) -> [ScheduledCallbackAction] {
            let elapsed = clock.elapsed
            var immediate: [ScheduledCallbackAction] = []
            for (index, occurrence) in occurrences.enumerated() {
                if occurrence.delay == .zero {
                    immediate.append(occurrence.acquire())
                } else {
                    pendingCallbacks.append(PendingCallbackDelivery(
                        id: id, occurrence: index, deadline: elapsed + occurrence.delay,
                        acquire: occurrence.acquire, onRetire: occurrence.retire, timer: nil
                    ))
                }
            }
            return immediate
        }

        fileprivate mutating func removeScheduledCallbacks(id: ScheduledCallbackID) -> [PendingCallbackDelivery] {
            let removed = pendingCallbacks.filter { $0.id === id }
            pendingCallbacks.removeAll { $0.id === id }
            return removed
        }

        fileprivate mutating func armNextContinuousCallback(id: ScheduledCallbackID, owner: MockSession) {
            guard case .continuous(let origin) = clock else { return }
            let next = pendingCallbacks.indices.lazy.filter { [pendingCallbacks] in
                pendingCallbacks[$0].id === id
            }.min {
                let left = pendingCallbacks[$0]
                let right = pendingCallbacks[$1]
                return (left.deadline, left.occurrence) < (right.deadline, right.occurrence)
            }
            guard let next, pendingCallbacks[next].timer == nil else { return }
            // Install the sleeper under the gate so a late deadline can wake immediately.
            let request = pendingCallbacks[next]
            pendingCallbacks[next].timer = owner.makeScheduledCallbackTimer(
                id: id, occurrence: request.occurrence, until: origin.advanced(by: request.deadline)
            )
        }

        fileprivate mutating func acquireContinuousCallback(
            id: ScheduledCallbackID, occurrence: Int
        ) -> AcquiredCallbackDeliveries? {
            let elapsed = clock.elapsed
            guard let index = pendingCallbacks.firstIndex(where: {
                $0.id === id && $0.occurrence == occurrence && $0.timer != nil && $0.deadline <= elapsed
            }) else { return nil }
            let request = pendingCallbacks.remove(at: index)
            return AcquiredCallbackDeliveries(requests: [request], actions: [request.acquire()])
        }

        fileprivate mutating func acquireDueCallbacks() -> AcquiredCallbackDeliveries {
            let elapsed = clock.elapsed
            let due = pendingCallbacks.filter { $0.deadline <= elapsed }.sorted { $0.deadline < $1.deadline }
            pendingCallbacks.removeAll { $0.deadline <= elapsed }
            return AcquiredCallbackDeliveries(requests: due, actions: due.map { $0.acquire() })
        }

        fileprivate mutating func retirePendingCallbacks() -> [PendingCallbackDelivery] {
            let retired = pendingCallbacks
            pendingCallbacks.removeAll()
            return retired
        }

        /// Returns true when the retained prefix changed. Call only under the session gate.
        mutating func discardEvents(through checkpoint: SessionCheckpoint) throws(SessionCheckpointError) -> Bool {
            try checkpoint.validate(for: epoch)
            guard !isFinished else { throw .finishedSession }
            let events = histories[epoch]!.events
            let firstRetained = events.firstEventIndex(after: checkpoint.watermark)
            let eventsRemoved = firstRetained > events.startIndex
            if eventsRemoved {
                // The last call event actually removed bounds gaps in call replay.
                histories[epoch]!.prunedThrough = events[firstRetained - 1].ordinal
                histories[epoch]!.events = Array(events[firstRetained...])
            }
            if let removed = histories[epoch]!.cancellationRequests.last(where: { $0.ordinal <= checkpoint.watermark }) {
                histories[epoch]!.cancellationRequestsPrunedThrough = removed.ordinal
                histories[epoch]!.cancellationRequests.removeAll { $0.ordinal <= checkpoint.watermark }
                return true
            }
            return eventsRemoved
        }

        func captureConsumption(in scope: SessionConsumptionScope) throws(SessionConsumptionError)
            -> (SessionSnapshot, SessionConsumptionClaims) {
            try scope.validate(for: epoch)
            return (snapshot(epoch: epoch)!, claimsByScope[scope.name] ?? SessionConsumptionClaims())
        }

        mutating func commitConsumption(_ prepared: PreparedSessionConsumption)
            throws(SessionConsumptionError) {
            let scope = prepared.result.scope
            try scope.validate(for: epoch)
            guard histories[epoch]!.prunedThrough == nil else { throw .historyUnavailable }
            let revision = claimsByScope[scope.name]?.revision ?? 0
            guard revision == prepared.scopeRevision else { throw .conflict }

            let ids = prepared.result.invocationIDs
            guard !ids.isEmpty else { return }
            claimsByScope[scope.name, default: SessionConsumptionClaims()].invocationIDs.formUnion(ids)
            claimsByScope[scope.name]!.revision += 1
        }

        fileprivate mutating func register(_ journal: any SessionJournalRegistration) {
            journals.append(WeakSessionJournal(value: journal))
        }

        mutating func admit(mockID: MockID, endpoint: EndpointID,
                            configurationRevision: RuleRevision) -> SessionEvent {
            precondition(!isFinished, "Cannot record an admission in a finished session")
            precondition(mockID.sessionID == epoch.sessionID, "Cannot admit a mock from another session")
            nextInvocationNumber += 1
            lastEventOrdinal += 1
            let event = SessionEvent(
                ordinal: lastEventOrdinal, elapsed: clock.elapsed, epoch: epoch, mockID: mockID, endpoint: endpoint,
                invocationID: SessionInvocationID(sessionID: epoch.sessionID, rawValue: nextInvocationNumber),
                configurationRevision: configurationRevision, phase: .admitted, origin: nil
            )
            active[event.invocationID] = event
            histories[epoch]!.activeInvocationCount += 1
            histories[epoch]!.events.append(event)
            return event
        }

        mutating func registerObservation(
            _ continuation: SessionObservationContinuation
        ) -> (snapshot: SessionSnapshot, elapsed: Duration, registrationID: UInt64?) {
            let (initial, elapsed) = timedSnapshot()
            guard !isFinished else { return (initial, elapsed, nil) }
            nextObservationID += 1
            observations[nextObservationID] = continuation
            return (initial, elapsed, nextObservationID)
        }

        mutating func removeObservation(_ id: UInt64) -> SessionObservationContinuation? {
            observations.removeValue(forKey: id)
        }

        func observationWake() -> SessionObservationDelivery? {
            guard !observations.isEmpty else { return nil }
            return SessionObservationDelivery(continuations: Array(observations.values), closes: false)
        }

        mutating func closeObservations() -> SessionObservationDelivery? {
            guard !observations.isEmpty else { return nil }
            let wake = SessionObservationDelivery(continuations: Array(observations.values), closes: true)
            observations.removeAll()
            return wake
        }

        mutating func registerQuiescenceWaiter(
            _ continuation: SessionQuiescenceContinuation
        ) -> SessionQuiescenceRegistration {
            if active.isEmpty {
                return .idle(snapshot(epoch: epoch)!)
            }
            nextQuiescenceWaiter += 1
            quiescenceWaiters[nextQuiescenceWaiter] = continuation
            return .waiting(nextQuiescenceWaiter)
        }

        mutating func removeQuiescenceWaiter(_ id: UInt64) -> SessionQuiescenceContinuation? {
            quiescenceWaiters.removeValue(forKey: id)
        }

        mutating func registerQuiescentReplacement(
            token: QuiescentReplacementToken, timeout: Duration, expectedEpoch: SessionEpoch?,
            continuation: CheckedContinuation<QuiescentReplacementOutcome, Never>,
            commit: @escaping QuiescentConfigurationCommit
        ) -> QuiescentReplacementRegistration {
            let now = clock.elapsed
            let request = QuiescentReplacement(token: token, deadline: now + timeout, expectedEpoch: expectedEpoch,
                                               continuation: continuation, commit: commit)
            if Task.isCancelled { return .settled(request.settle(.cancelled)) }
            if let outcome = replacementFailure(request, at: now) { return .settled(request.settle(outcome)) }
            if active.isEmpty { return .settled(request.publishConfiguration(using: clock)) }

            quiescentReplacements.append(request)
            return .waiting(until: clock.continuousInstant(at: request.deadline))
        }

        mutating func cancelQuiescentReplacement(
            _ token: QuiescentReplacementToken
        ) -> QuiescentReplacementDelivery? {
            guard let index = quiescentReplacements.firstIndex(where: { $0.token === token }) else { return nil }
            return quiescentReplacements.remove(at: index).settle(.cancelled)
        }

        private func replacementFailure(
            _ request: QuiescentReplacement, at elapsed: Duration
        ) -> QuiescentReplacementOutcome? {
            if let expected = request.expectedEpoch, expected != epoch { return .invalidated(.staleScope) }
            if isFinished { return .invalidated(.finishedSession) }
            return elapsed >= request.deadline ? .deadlineExceeded : nil
        }

        mutating func resolveQuiescentReplacements(
            publishAtIdle: Bool, at elapsed: Duration? = nil
        ) -> [QuiescentReplacementDelivery] {
            guard !quiescentReplacements.isEmpty else { return [] }
            let now = elapsed ?? clock.elapsed
            var pending: [QuiescentReplacement] = []
            var deliveries: [QuiescentReplacementDelivery] = []
            for request in quiescentReplacements {
                if let outcome = replacementFailure(request, at: now) {
                    deliveries.append(request.settle(outcome))
                } else if publishAtIdle {
                    deliveries.append(request.publishConfiguration(using: clock))
                } else {
                    pending.append(request)
                }
            }
            quiescentReplacements = pending
            return deliveries
        }

        mutating func registerDelayedAnswer(
            for invocationID: SessionInvocationID, after delay: Duration,
            continuation: CheckedContinuation<DelayedAnswerWake, Never>
        ) -> DelayedAnswerRegistration {
            precondition(active[invocationID] != nil, "A delayed answer requires an active invocation")
            if Task.isCancelled || activeCancellationRequests.contains(invocationID) {
                let wake = recordCancellationRequest(for: invocationID)
                return .cancelled(wake)
            }
            let deadline = clock.elapsed + delay
            let request = PendingDelayedAnswer(deadline: deadline, continuation: continuation)
            precondition(delayedAnswers.updateValue(request, forKey: invocationID) == nil,
                         "An invocation can wait for one reserved answer")
            return .waiting(until: clock.continuousInstant(at: deadline))
        }

        mutating func cancelDelayedAnswer(for invocationID: SessionInvocationID) -> DelayedAnswerDelivery? {
            delayedAnswers.removeValue(forKey: invocationID)?.settle(.cancelled)
        }

        mutating func acquireDelayedAnswer(for invocationID: SessionInvocationID) -> DelayedAnswerDelivery? {
            delayedAnswers.removeValue(forKey: invocationID)?.settle(.elapsed)
        }

        fileprivate mutating func acquireDueDelayedAnswers() -> [DelayedAnswerDelivery] {
            let elapsed = clock.elapsed
            let due = delayedAnswers.compactMap { $0.value.deadline <= elapsed ? $0.key : nil }
            return due.compactMap { acquireDelayedAnswer(for: $0) }
        }

        mutating func recordCancellationRequest(for invocationID: SessionInvocationID) -> SessionObservationDelivery? {
            guard let admission = active[invocationID], activeCancellationRequests.insert(invocationID).inserted else {
                return nil
            }
            lastEventOrdinal += 1
            histories[admission.epoch]!.cancellationRequests.append(SessionCancellationRequest(
                ordinal: lastEventOrdinal, elapsed: clock.elapsed, admission: admission
            ))
            return observationWake()
        }

        mutating func complete(
            _ invocationID: SessionInvocationID, phase: CallPhase, origin: CallOrigin? = nil,
            constructedMockID: MockID? = nil
        ) -> (event: SessionEvent, delivery: SessionQuiescenceDelivery?) {
            precondition(phase != .admitted, "Completion requires a terminal phase")
            if let constructedMockID {
                precondition(phase == .returned && constructedMockID.sessionID == epoch.sessionID,
                             "A successful construction must attach an instance from this session")
            }
            guard let admission = active.removeValue(forKey: invocationID) else {
                preconditionFailure("No active invocation matches this completion")
            }
            activeCancellationRequests.remove(invocationID)
            lastEventOrdinal += 1
            let event = SessionEvent(
                ordinal: lastEventOrdinal, elapsed: clock.elapsed, epoch: admission.epoch, mockID: admission.mockID,
                endpoint: admission.endpoint, invocationID: invocationID,
                configurationRevision: admission.configurationRevision, phase: phase, origin: origin,
                constructedMockNumber: constructedMockID?.rawValue ?? 0
            )
            histories[admission.epoch]!.activeInvocationCount -= 1
            histories[admission.epoch]!.events.append(event)

            guard active.isEmpty else { return (event, nil) }
            // Publication is part of the zero-active transaction, before any next admission.
            let replacements = resolveQuiescentReplacements(publishAtIdle: true, at: event.elapsed)
            guard !quiescenceWaiters.isEmpty || !replacements.isEmpty else { return (event, nil) }
            let delivery = SessionQuiescenceDelivery(snapshot: snapshot(epoch: epoch)!,
                                                     waiters: Array(quiescenceWaiters.values),
                                                     replacements: replacements)
            quiescenceWaiters.removeAll()
            return (event, delivery)
        }

        fileprivate mutating func finishIfQuiescent() throws(SessionFinishError) -> (SessionSnapshot, SessionRetirement?) {
            guard active.isEmpty else { throw .activeInvocations(count: active.count) }
            // Keep the final cutoff stable even if the clock advances before observers wake.
            guard finishedElapsed == nil else { return (snapshot(epoch: epoch)!, nil) }
            finishedElapsed = clock.elapsed
            let registered = journals.compactMap(\.value)
            let retired = registered.compactMap { $0.discardCapturesOnFinish() }
            let retirement = SessionRetirement(epoch: epoch, journals: registered, history: retired)
            return (snapshot(epoch: epoch)!, retirement)
        }

        fileprivate mutating func resetHistory(_ mode: SessionResetMode, restartingSequences: Bool)
            throws(SessionResetError) -> SessionRetirement {
            guard !isFinished else { throw .finished }
            if mode == .requireQuiescence {
                guard active.isEmpty else { throw .activeInvocations(count: active.count) }
                histories.removeAll()
            }

            // Keep strong references and retired typed payloads until after the session unlocks.
            let registered = journals.compactMap(\.value)
            journals = registered.map { WeakSessionJournal(value: $0) }
            let retired = registered.map { $0.discardHistory(restartingSequences: restartingSequences) }
            epoch = SessionEpoch(sessionID: epoch.sessionID, rawValue: epoch.rawValue + 1)
            histories[epoch] = EpochHistory()
            claimsByScope.removeAll()
            return SessionRetirement(epoch: epoch, journals: registered, history: retired)
        }
    }
}
