typealias SessionObservationContinuation = AsyncStream<Void>.Continuation

struct SessionObservationDelivery: Sendable {
    let continuations: [SessionObservationContinuation]
    let closes: Bool

    func publish() {
        for continuation in continuations {
            continuation.yield(())
            if closes {
                continuation.finish()
            }
        }
    }
}

/// A session event subscription with a consistent starting snapshot and checkpoint.
/// Notifications can coalesce and carry no event data. Replay from the last checkpoint
/// after each wake. Use one iterator per lease and cancel it when no longer needed.
public final class SessionObservation: Sendable {
    public let initialSnapshot: SessionSnapshot
    public let checkpoint: SessionCheckpoint
    public let notifications: AsyncStream<Void>
    private let session: MockSession
    private let registrationID: UInt64?
    private let continuation: SessionObservationContinuation

    fileprivate init(
        session: MockSession,
        initialSnapshot: SessionSnapshot,
        registrationID: UInt64?,
        notifications: AsyncStream<Void>,
        continuation: SessionObservationContinuation
    ) {
        self.session = session
        self.initialSnapshot = initialSnapshot
        self.checkpoint = SessionCheckpoint(snapshot: initialSnapshot)
        self.registrationID = registrationID
        self.notifications = notifications
        self.continuation = continuation
    }

    /// Unregisters the observation and closes its notifications. Repeated calls are safe.
    public func cancel() {
        if let registrationID {
            session.unregisterObservation(registrationID)
        }
        continuation.finish()
    }

    deinit { cancel() }
}

extension MockSession {
    /// Captures the starting snapshot and subscribes to changes in the same transaction.
    /// Reset and finish close the lease after sending a wake so readers can replay or
    /// diagnose the change. A finished session returns an already closed observation.
    public func observeChanges() -> SessionObservation {
        let (notifications, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (snapshot, registrationID) = withLock { $0.registerObservation(continuation) }
        if let registrationID {
            continuation.onTermination = { [weak self] _ in
                self?.unregisterObservation(registrationID)
            }
        } else {
            continuation.finish()
        }
        return SessionObservation(session: self, initialSnapshot: snapshot, registrationID: registrationID,
                                  notifications: notifications, continuation: continuation)
    }

    fileprivate func unregisterObservation(_ id: UInt64) {
        let retired = withLock { $0.removeObservation(id) }
        withExtendedLifetime(retired) {}
    }
}
