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
}

public enum SessionResetMode: Sendable {
    /// Discard all history after every session invocation has completed.
    case requireQuiescence
    /// Retain earlier metadata so active invocations can finish in their original epochs.
    case detachActive
}

public enum SessionResetError: Error, Equatable, Sendable {
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

    public init() {
        let id = SessionID(rawValue: UUID())
        self.id = id
        state = CriticalState(State(sessionID: id))
    }

    public func makeMock() -> MockScope {
        let mockID = state.withLock { $0.makeMockID() }
        return MockScope(id: mockID, session: self)
    }

    public func snapshot() -> SessionSnapshot {
        state.withLock { $0.snapshot(epoch: $0.epoch)! }
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
        let retirement = try state.withLock { (state: inout State) throws(SessionResetError) in
            try state.resetHistory(mode)
        }
        // User destructors and last-owner journal destruction may reenter this session.
        withExtendedLifetime(retirement) {}
        return retirement.epoch
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
        }

        private(set) var epoch: SessionEpoch
        private var nextMockNumber: UInt64 = 0
        private var nextInvocationNumber: UInt64 = 0
        private var lastEventOrdinal: UInt64 = 0
        private var histories: [SessionEpoch: EpochHistory]
        private var active: [SessionInvocationID: SessionEvent] = [:]
        private var journals: [WeakSessionJournal] = []
        private var nextQuiescenceWaiter: UInt64 = 0
        private var quiescenceWaiters: [UInt64: SessionQuiescenceContinuation] = [:]

        var quiescenceWaiterCount: Int { quiescenceWaiters.count }

        fileprivate init(sessionID: SessionID) {
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
                watermark: lastEventOrdinal
            )
        }

        fileprivate mutating func register(_ journal: any SessionJournalRegistration) {
            journals.append(WeakSessionJournal(value: journal))
        }

        mutating func admit(mockID: MockID, endpoint: EndpointID,
                            configurationRevision: RuleRevision) -> SessionEvent {
            precondition(mockID.sessionID == epoch.sessionID, "Cannot admit a mock from another session")
            nextInvocationNumber += 1
            lastEventOrdinal += 1
            let event = SessionEvent(
                ordinal: lastEventOrdinal, epoch: epoch, mockID: mockID, endpoint: endpoint,
                invocationID: SessionInvocationID(sessionID: epoch.sessionID, rawValue: nextInvocationNumber),
                configurationRevision: configurationRevision, phase: .admitted
            )
            active[event.invocationID] = event
            histories[epoch]!.activeInvocationCount += 1
            histories[epoch]!.events.append(event)
            return event
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
                ordinal: lastEventOrdinal, epoch: admission.epoch, mockID: admission.mockID,
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

        fileprivate mutating func resetHistory(_ mode: SessionResetMode)
            throws(SessionResetError) -> SessionRetirement {
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
