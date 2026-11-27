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
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint, message: message,
                              source: source, watermark: admission?.ordinal ?? 0)
        if !bufferOrphan(issue, closedEpoch: closedEpoch, terminating: true) {
            reporter.report(issue)
        }
        fatalError(message)
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
}

/// A copy of one epoch's metadata as of a session-wide event watermark.
public struct SessionSnapshot: Equatable, Sendable {
    public let sessionID: SessionID
    public let epoch: SessionEpoch
    public let events: [SessionEvent]
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
    func discardHistory() -> any Sendable
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
        for request in pending where request.timer != nil { request.retire() }
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
    public func advanceClock(by duration: Duration) throws(SessionClockError) {
        let (wake, replacements, callbacks) = try state.withLock { (state: inout State) throws(SessionClockError) in
            try state.advanceClock(by: duration)
            return (state.observationWake(), state.resolveQuiescentReplacements(publishAtIdle: false),
                    state.acquireDueCallbacks())
        }
        for replacement in replacements { replacement.publish() }
        wake?.publish()
        callbacks.publish()
    }

    func removeScheduledCallbacks(id: ScheduledCallbackID) -> [PendingCallbackDelivery] {
        let removed = state.withLock { $0.removeScheduledCallbacks(id: id) }
        for request in removed { request.timer?.cancel() }
        return removed
    }

    private func makeScheduledCallbackTimer(
        id: ScheduledCallbackID, until deadline: ContinuousClock.Instant
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline, tolerance: .zero)
                try Task.checkCancellation()
            } catch {
                return
            }
            self?.deliverScheduledCallback(id: id)
        }
    }

    private func deliverScheduledCallback(id: ScheduledCallbackID) {
        let acquired = state.withLock { $0.acquireContinuousCallback(id: id) }
        acquired?.publish()
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

    /// Starts a new epoch without changing the configured rules or reusing identities.
    /// Detachment preserves earlier event metadata. Typed argument history is discarded.
    @discardableResult
    public func resetHistory(_ mode: SessionResetMode = .requireQuiescence)
        throws(SessionResetError) -> SessionEpoch {
        let (retirement, wake, replacements, callbacks) = try state.withLock {
            (state: inout State) throws(SessionResetError) in
            let retirement = try state.resetHistory(mode)
            return (retirement, state.closeObservations(), state.resolveQuiescentReplacements(publishAtIdle: false),
                    state.retirePendingCallbacks())
        }
        for callback in callbacks { callback.retire() }
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
        for callback in callbacks { callback.retire() }
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
                events: history.events, activeInvocationCount: history.activeInvocationCount,
                watermark: lastEventOrdinal, prunedThrough: history.prunedThrough, isFinished: isFinished
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
            id: ScheduledCallbackID, occurrences: [ScheduledCallbackOccurrence], continuousOwner: MockSession?
        ) throws(CallbackSchedulingError) -> [ScheduledCallbackAction] {
            if case .continuous = clock {
                guard continuousOwner != nil, occurrences.count == 1 else { throw .requiresManualClock }
            }
            let elapsed = clock.elapsed
            var immediate: [ScheduledCallbackAction] = []
            for (index, occurrence) in occurrences.enumerated() {
                if occurrence.delay == .zero {
                    immediate.append(occurrence.acquire())
                } else {
                    let deadline = elapsed + occurrence.delay
                    // Install the timer with its request so an early wake cannot race registration.
                    let timer = clock.continuousInstant(at: deadline).flatMap { instant in
                        continuousOwner?.makeScheduledCallbackTimer(id: id, until: instant)
                    }
                    pendingCallbacks.append(PendingCallbackDelivery(
                        id: id, occurrence: index, deadline: deadline,
                        acquire: occurrence.acquire, onRetire: occurrence.retire, timer: timer
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

        fileprivate mutating func acquireContinuousCallback(id: ScheduledCallbackID) -> AcquiredCallbackDeliveries? {
            let elapsed = clock.elapsed
            guard let index = pendingCallbacks.firstIndex(where: { $0.id === id && $0.deadline <= elapsed }) else {
                return nil
            }
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
            guard firstRetained > events.startIndex else { return false }

            // A checkpoint watermark is session-wide and may refer to an archived epoch.
            // The last event actually removed is the only evidence of lost history.
            histories[epoch]!.prunedThrough = events[firstRetained - 1].ordinal
            histories[epoch]!.events = Array(events[firstRetained...])
            return true
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

        mutating func complete(
            _ invocationID: SessionInvocationID, phase: CallPhase, origin: CallOrigin? = nil
        ) -> (event: SessionEvent, delivery: SessionQuiescenceDelivery?) {
            precondition(phase != .admitted, "Completion requires a terminal phase")
            guard let admission = active.removeValue(forKey: invocationID) else {
                preconditionFailure("No active invocation matches this completion")
            }
            lastEventOrdinal += 1
            let event = SessionEvent(
                ordinal: lastEventOrdinal, elapsed: clock.elapsed, epoch: admission.epoch, mockID: admission.mockID,
                endpoint: admission.endpoint, invocationID: invocationID,
                configurationRevision: admission.configurationRevision, phase: phase, origin: origin
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

        fileprivate mutating func resetHistory(_ mode: SessionResetMode)
            throws(SessionResetError) -> SessionRetirement {
            guard !isFinished else { throw .finished }
            if mode == .requireQuiescence {
                guard active.isEmpty else { throw .activeInvocations(count: active.count) }
                histories.removeAll()
            }

            // Keep strong references and retired typed payloads until after the session unlocks.
            let registered = journals.compactMap(\.value)
            journals = registered.map { WeakSessionJournal(value: $0) }
            let retired = registered.map { $0.discardHistory() }
            epoch = SessionEpoch(sessionID: epoch.sessionID, rawValue: epoch.rawValue + 1)
            histories[epoch] = EpochHistory()
            claimsByScope.removeAll()
            return SessionRetirement(epoch: epoch, journals: registered, history: retired)
        }
    }
}
