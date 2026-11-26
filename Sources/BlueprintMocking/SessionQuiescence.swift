/// A quiescence wait did not observe a zero-active snapshot before its deadline.
public enum SessionQuiescenceError: Error, Equatable {
    case deadlineExceeded
}

/// The session cannot accept a quiescent configuration replacement.
public enum QuiescentConfigurationError: Error, Equatable, Sendable {
    case activeInvocations(count: Int)
    case finishedSession
    case staleScope
}

/// The deadline-based configuration replacement could not publish in its time window.
public enum QuiescentConfigurationWaitError: Error, Equatable, Sendable {
    case invalidDuration
    case deadlineExceeded
}

typealias SessionQuiescenceContinuation = AsyncStream<SessionSnapshot>.Continuation

enum SessionQuiescenceRegistration: Sendable {
    case idle(SessionSnapshot)
    case waiting(UInt64)
}

struct SessionQuiescenceDelivery: Sendable {
    let snapshot: SessionSnapshot
    let waiters: [SessionQuiescenceContinuation]
    let replacements: [QuiescentReplacementDelivery]

    func publish() {
        for replacement in replacements { replacement.publish() }
        for waiter in waiters {
            waiter.yield(snapshot)
            waiter.finish()
        }
    }
}

extension MockSession {
    /// Observes zero active invocations across the session, including detached epochs.
    /// The returned snapshot is captured at the zero-active observation. Producers may
    /// admit new calls after that observation.
    ///
    /// A snapshot must be observed before the exclusive deadline. Cancellation throws
    /// `CancellationError`, and an elapsed deadline throws `SessionQuiescenceError.deadlineExceeded`.
    public func waitForQuiescence<C: Clock>(until deadline: C.Instant, clock: C) async throws -> SessionSnapshot {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw SessionQuiescenceError.deadlineExceeded }

        let (notifications, continuation) = AsyncStream<SessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let registration = withLock { $0.registerQuiescenceWaiter(continuation) }
        switch registration {
        case .idle(let snapshot):
            continuation.finish()
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SessionQuiescenceError.deadlineExceeded }
            return snapshot

        case .waiting(let id):
            defer {
                let retired = withLock { $0.removeQuiescenceWaiter(id) }
                withExtendedLifetime(retired) { continuation.finish() }
            }
            do {
                let snapshot = try await withThrowingTaskGroup(of: SessionSnapshot.self) { group in
                    group.addTask {
                        var iterator = notifications.makeAsyncIterator()
                        guard let snapshot = await iterator.next() else { throw CancellationError() }
                        guard clock.now < deadline else { throw SessionQuiescenceError.deadlineExceeded }
                        return snapshot
                    }
                    group.addTask {
                        try await clock.sleep(until: deadline, tolerance: .zero)
                        throw SessionQuiescenceError.deadlineExceeded
                    }
                    defer { group.cancelAll() }
                    guard let snapshot = try await group.next() else { throw CancellationError() }
                    return snapshot
                }
                try Task.checkCancellation()
                return snapshot
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
    }
}
