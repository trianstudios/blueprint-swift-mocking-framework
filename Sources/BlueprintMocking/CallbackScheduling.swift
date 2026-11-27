/// An error raised before a callback has been scheduled.
public enum CallbackSchedulingError: Error, Equatable, Sendable {
    case unavailable
    case requiresManualClock
    case negativeDelay
}

/// The current outcome of a single scheduled delivery.
public enum ScheduledCallbackOutcome<Output: Sendable>: Sendable {
    /// The request is queued or its acquired callback is still executing.
    case pending
    case delivered(Output)
    /// Cancellation removed the queued delivery before acquisition.
    case cancelled
    /// The capture was retired or was no longer owned when delivery came due.
    case unavailable
}

extension ScheduledCallbackOutcome: Equatable where Output: Equatable {}

// A timer retains its token until the task exits, so a late wake cannot match a new receipt.
final class ScheduledCallbackID: Sendable {}

private struct WeakCallbackSession: Sendable {
    weak var value: MockSession?
}

/// A receipt for a scheduled callback. Reading it does not run or reschedule the callback.
public final class ScheduledCallbackDelivery<Output: Sendable>: Sendable {
    let id = ScheduledCallbackID()
    private let owner: WeakCallbackSession
    private let state = CriticalState<ScheduledCallbackOutcome<Output>>(.pending)

    init(session: MockSession) {
        owner = WeakCallbackSession(value: session)
    }

    public var outcome: ScheduledCallbackOutcome<Output> {
        state.withLock { $0 }
    }

    /// Cancels this receipt's queued request and sets its outcome to cancelled.
    /// Returns false if the request is no longer queued, including after acquisition.
    @discardableResult
    public func cancel() -> Bool {
        guard let requests = owner.value?.removeScheduledCallbacks(id: id),
              !requests.isEmpty else { return false }
        resolve(.cancelled)
        // Release the removed request's captured input outside the session gate.
        withExtendedLifetime(requests) {}
        return true
    }

    func resolve(_ outcome: ScheduledCallbackOutcome<Output>) {
        state.withLock { $0 = outcome }
    }
}

/// An error raised before a one-shot callback attempt has been scheduled.
public enum OneShotCallbackSchedulingError: Error, Equatable, Sendable {
    case negativeDelay
    case requiresManualClock
    case delivery(OneShotCallbackDeliveryError)
}

/// The current outcome of one scheduled attempt on a one-shot capture.
public enum ScheduledOneShotCallbackOutcome<Output: Sendable>: Sendable {
    /// The attempt is queued or its acquired callback is still running.
    case pending
    case delivered(Output)
    /// Cancellation removed this receipt's queued attempt.
    case cancelled
    /// The shared capture could not be acquired, or its session retired this attempt.
    case rejected(OneShotCallbackDeliveryError)
}

extension ScheduledOneShotCallbackOutcome: Equatable where Output: Equatable {}

/// A receipt for a scheduled attempt on a one-shot capture.
public final class ScheduledOneShotCallbackDelivery<Output: Sendable>: Sendable {
    private let request: ScheduledCallbackDelivery<Result<Output, OneShotCallbackDeliveryError>>

    init(session: MockSession) {
        request = ScheduledCallbackDelivery(session: session)
    }

    var id: ScheduledCallbackID { request.id }

    public var outcome: ScheduledOneShotCallbackOutcome<Output> {
        switch request.outcome {
        case .pending: .pending
        case .delivered(.success(let output)): .delivered(output)
        case .delivered(.failure(let reason)): .rejected(reason)
        case .cancelled: .cancelled
        case .unavailable: .rejected(.unavailable)
        }
    }

    /// Withdraws this queued attempt. Other attempts can still claim a pending capture.
    @discardableResult
    public func cancel() -> Bool {
        request.cancel()
    }

    func resolve(_ result: Result<Output, OneShotCallbackDeliveryError>) {
        request.resolve(.delivered(result))
    }
}

/// The receipt for a finite series of invocations of the same captured callback.
public final class ScheduledCallbackSeries<Output: Sendable>: Sendable {
    let id = ScheduledCallbackID()
    private let owner: WeakCallbackSession
    private let state: CriticalState<[ScheduledCallbackOutcome<Output>]>

    init(session: MockSession, count: Int) {
        owner = WeakCallbackSession(value: session)
        state = CriticalState(Array(repeating: .pending, count: count))
    }

    /// A snapshot of the outcomes in the order in which the caller supplied the delays.
    public var outcomes: [ScheduledCallbackOutcome<Output>] {
        state.withLock { $0 }
    }

    /// Cancels the still-queued occurrences in one transaction and returns their count.
    /// Acquired occurrences can finish even if their outcomes are still pending.
    @discardableResult
    public func cancelPending() -> Int {
        guard let requests = owner.value?.removeScheduledCallbacks(id: id),
              !requests.isEmpty else { return 0 }
        state.withLock { outcomes in
            for request in requests {
                outcomes[request.occurrence] = .cancelled
            }
        }
        withExtendedLifetime(requests) {}
        return requests.count
    }

    func resolve(_ outcome: ScheduledCallbackOutcome<Output>, at occurrence: Int) {
        state.withLock { $0[occurrence] = outcome }
    }
}

typealias ScheduledCallbackAction = @Sendable () -> Void

enum ScheduledCallbackRetirement: Sendable {
    case unavailable
    case finished
}

struct ScheduledCallbackOccurrence: Sendable {
    let delay: Duration
    let acquire: @Sendable () -> ScheduledCallbackAction
    let retire: @Sendable (ScheduledCallbackRetirement) -> Void
}

struct PendingCallbackDelivery: Sendable {
    let id: ScheduledCallbackID
    let occurrence: Int
    let deadline: Duration
    /// Acquires the closure under the session gate and returns work to do after unlocking.
    let acquire: @Sendable () -> ScheduledCallbackAction
    let onRetire: @Sendable (ScheduledCallbackRetirement) -> Void
    // Only the next queued occurrence of a continuous series has a sleeper.
    var timer: Task<Void, Never>?

    func retire(because reason: ScheduledCallbackRetirement) {
        timer?.cancel()
        onRetire(reason)
    }
}

struct AcquiredCallbackDeliveries: Sendable {
    let requests: [PendingCallbackDelivery]
    let actions: [ScheduledCallbackAction]

    func publish() {
        for action in actions { action() }
        // Dropping captured inputs or closures can run user destructors.
        withExtendedLifetime(requests) {}
    }
}
