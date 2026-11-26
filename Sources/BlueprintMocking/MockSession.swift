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

/// The explicitly selected session and identity for a mock's endpoints.
public struct MockScope: Sendable {
    public let id: MockID
    public let session: MockSession
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
    private let state: CriticalState<State>

    public convenience init() {
        self.init(clock: .continuous)
    }

    public init(clock: SessionClockMode) {
        let id = SessionID(rawValue: UUID())
        self.id = id
        state = CriticalState(State(sessionID: id, clock: SessionClockState(clock)))
    }

    public func makeMock() -> MockScope {
        let mockID = state.withLock { $0.makeMockID() }
        return MockScope(id: mockID, session: self)
    }

    public func snapshot() -> SessionSnapshot {
        state.withLock { $0.snapshot(epoch: $0.epoch)! }
    }

    /// Moves a manual session clock forward without adding an event. Observers are
    /// notified after the new clock reading is published.
    public func advanceClock(by duration: Duration) throws(SessionClockError) {
        let wake = try state.withLock { (state: inout State) throws(SessionClockError) in
            try state.advanceClock(by: duration)
            return state.observationWake()
        }
        wake?.publish()
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
        let (retirement, wake) = try state.withLock { (state: inout State) throws(SessionResetError) in
            let retirement = try state.resetHistory(mode)
            return (retirement, state.closeObservations())
        }
        wake?.publish()
        // User destructors and last-owner journal destruction may reenter this session.
        withExtendedLifetime(retirement) {}
        return retirement.epoch
    }

    /// Closes admission at zero active calls across all epochs and preserves the final metadata.
    /// Repeated calls return the same final snapshot. The caller owns teardown of its tasks.
    @discardableResult
    public func finishIfQuiescent() throws(SessionFinishError) -> SessionSnapshot {
        let (snapshot, wake) = try state.withLock { (state: inout State) throws(SessionFinishError) in
            let snapshot = try state.finishIfQuiescent()
            return (snapshot, state.closeObservations())
        }
        wake?.publish()
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

        var isFinished: Bool { finishedElapsed != nil }
        private var nextMockNumber: UInt64 = 0
        private var nextInvocationNumber: UInt64 = 0
        private var lastEventOrdinal: UInt64 = 0
        private var histories: [SessionEpoch: EpochHistory]
        private var active: [SessionInvocationID: SessionEvent] = [:]
        private var journals: [WeakSessionJournal] = []
        private var nextQuiescenceWaiter: UInt64 = 0
        private var quiescenceWaiters: [UInt64: SessionQuiescenceContinuation] = [:]
        private var nextObservationID: UInt64 = 0
        private var observations: [UInt64: SessionObservationContinuation] = [:]

        var observationCount: Int { observations.count }

        var quiescenceWaiterCount: Int { quiescenceWaiters.count }

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

        fileprivate func timedSnapshot() -> (snapshot: SessionSnapshot, elapsed: Duration) {
            (snapshot(epoch: epoch)!, finishedElapsed ?? clock.elapsed)
        }

        fileprivate func continuousInstant(at elapsed: Duration) -> ContinuousClock.Instant? {
            clock.continuousInstant(at: elapsed)
        }

        fileprivate mutating func advanceClock(by duration: Duration) throws(SessionClockError) {
            try clock.advance(by: duration)
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
                configurationRevision: configurationRevision, phase: .admitted
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

        mutating func complete(
            _ invocationID: SessionInvocationID, phase: CallPhase
        ) -> SessionQuiescenceDelivery? {
            precondition(phase != .admitted, "Completion requires a terminal phase")
            guard let admission = active.removeValue(forKey: invocationID) else {
                preconditionFailure("No active invocation matches this completion")
            }
            lastEventOrdinal += 1
            let event = SessionEvent(
                ordinal: lastEventOrdinal, elapsed: clock.elapsed, epoch: admission.epoch, mockID: admission.mockID,
                endpoint: admission.endpoint, invocationID: invocationID,
                configurationRevision: admission.configurationRevision, phase: phase
            )
            histories[admission.epoch]!.activeInvocationCount -= 1
            histories[admission.epoch]!.events.append(event)

            guard active.isEmpty, !quiescenceWaiters.isEmpty else { return nil }
            let delivery = SessionQuiescenceDelivery(snapshot: snapshot(epoch: epoch)!,
                                                     waiters: Array(quiescenceWaiters.values))
            quiescenceWaiters.removeAll()
            return delivery
        }

        fileprivate mutating func finishIfQuiescent() throws(SessionFinishError) -> SessionSnapshot {
            guard active.isEmpty else { throw .activeInvocations(count: active.count) }
            // Keep the final cutoff stable even if the clock advances before observers wake.
            if finishedElapsed == nil { finishedElapsed = clock.elapsed }
            return snapshot(epoch: epoch)!
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
            return SessionRetirement(epoch: epoch, journals: registered, history: retired)
        }
    }
}
