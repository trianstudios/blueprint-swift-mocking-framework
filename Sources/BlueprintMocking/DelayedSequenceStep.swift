enum DelayedAnswerWake: Sendable {
    case elapsed
    case cancelled
}

enum DelayedAnswerRegistration: Sendable {
    case waiting(until: ContinuousClock.Instant?)
    case cancelled(SessionObservationDelivery?)
}

struct PendingDelayedAnswer: Sendable {
    let deadline: Duration
    let continuation: CheckedContinuation<DelayedAnswerWake, Never>

    func settle(_ outcome: DelayedAnswerWake) -> DelayedAnswerDelivery {
        DelayedAnswerDelivery(continuation: continuation, outcome: outcome)
    }
}

struct DelayedAnswerDelivery: Sendable {
    let continuation: CheckedContinuation<DelayedAnswerWake, Never>
    let outcome: DelayedAnswerWake

    func publish() { continuation.resume(returning: outcome) }
}

extension MockSession {
    /// The invocation's cancellation handler records and settles cancellation under
    /// the same gate. Registration also handles an already-cancelled invocation.
    func waitForDelayedAnswer(_ invocationID: SessionInvocationID, after delay: Duration) async -> DelayedAnswerWake {
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return await withCheckedContinuation { continuation in
            let registration = withLock {
                $0.registerDelayedAnswer(for: invocationID, after: delay, continuation: continuation)
            }
            switch registration {
            case .cancelled(let wake):
                wake?.publish()
                continuation.resume(returning: .cancelled)
            case .waiting(let deadline):
                guard let deadline else { return }
                timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline, tolerance: .zero) }
                    catch { return }
                    guard let self else { return }
                    let delivery = withLock { $0.acquireDelayedAnswer(for: invocationID) }
                    delivery?.publish()
                }
            }
        }
    }
}
