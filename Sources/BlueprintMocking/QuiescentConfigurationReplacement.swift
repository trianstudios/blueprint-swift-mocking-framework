/// The identity of one cancellation/commit race. Only the session resolves it.
final class QuiescentReplacementToken: Sendable {}

enum QuiescentReplacementOutcome: Sendable {
    case committed(RuleRevision)
    case cancelled
    case invalidated(QuiescentConfigurationError)
    case deadlineExceeded

    func value() throws -> RuleRevision {
        switch self {
        case .committed(let revision): return revision
        case .cancelled: throw CancellationError()
        case .invalidated(let error): throw error
        case .deadlineExceeded: throw QuiescentConfigurationWaitError.deadlineExceeded
        }
    }
}

typealias QuiescentConfigurationCommit = @Sendable (SessionClockState, Duration) -> (RuleRevision, any Sendable)?

struct QuiescentReplacement: Sendable {
    let token: QuiescentReplacementToken
    let deadline: Duration
    let expectedEpoch: SessionEpoch?
    let continuation: CheckedContinuation<QuiescentReplacementOutcome, Never>
    /// Only internal journal publication is allowed here. Transfer the old plan out of the session gate.
    let commit: QuiescentConfigurationCommit

    func settle(_ outcome: QuiescentReplacementOutcome) -> QuiescentReplacementDelivery {
        QuiescentReplacementDelivery(request: self, outcome: outcome, retired: nil)
    }

    func publishConfiguration(using clock: SessionClockState) -> QuiescentReplacementDelivery {
        guard let (revision, retired) = commit(clock, deadline) else { return settle(.deadlineExceeded) }
        return QuiescentReplacementDelivery(request: self, outcome: .committed(revision), retired: retired)
    }
}

struct QuiescentReplacementDelivery: Sendable {
    // Keep the pending request's captures and any replaced plan alive until off-lock.
    let request: QuiescentReplacement
    let outcome: QuiescentReplacementOutcome
    let retired: (any Sendable)?

    func publish() {
        withExtendedLifetime((request, retired)) { request.continuation.resume(returning: outcome) }
    }
}

enum QuiescentReplacementRegistration: Sendable {
    case settled(QuiescentReplacementDelivery)
    case waiting(until: ContinuousClock.Instant?)
}

extension MockSession {
    func replaceWhenQuiescent(
        within timeout: Duration, expectedEpoch: SessionEpoch?,
        commit: @escaping QuiescentConfigurationCommit
    ) async throws -> RuleRevision {
        guard timeout > .zero else { throw QuiescentConfigurationWaitError.invalidDuration }
        let token = QuiescentReplacementToken()
        let outcome = await withTaskCancellationHandler {
            var timer: Task<Void, Never>?
            defer { timer?.cancel() }
            return await withCheckedContinuation { continuation in
                let registration = withLock {
                    $0.registerQuiescentReplacement(
                        token: token, timeout: timeout, expectedEpoch: expectedEpoch,
                        continuation: continuation, commit: commit
                    )
                }
                switch registration {
                case .settled(let delivery):
                    delivery.publish()
                case .waiting(let deadline):
                    if let deadline {
                        timer = Task { [weak self] in
                            do { try await ContinuousClock().sleep(until: deadline, tolerance: .zero) }
                            catch { return }
                            guard let self else { return }
                            let deliveries = withLock { $0.resolveQuiescentReplacements(publishAtIdle: false) }
                            for delivery in deliveries { delivery.publish() }
                        }
                    }
                }
            }
        } onCancel: {
            // Registration checks the waiting task's cancellation flag under the same gate.
            // An absent token has either not registered yet or already reached a final outcome.
            let delivery = self.withLock { $0.cancelQuiescentReplacement(token) }
            delivery?.publish()
        }
        return try outcome.value()
    }
}
