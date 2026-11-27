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

/// A receipt for a scheduled callback. Reading it does not run or reschedule the callback.
public final class ScheduledCallbackDelivery<Output: Sendable>: Sendable {
    private struct WeakSession: Sendable {
        weak var value: MockSession?
    }

    private let owner: WeakSession
    private let state = CriticalState<ScheduledCallbackOutcome<Output>>(.pending)

    init(session: MockSession) {
        owner = WeakSession(value: session)
    }

    public var outcome: ScheduledCallbackOutcome<Output> {
        state.withLock { $0 }
    }

    /// Cancels this receipt's queued request and sets its outcome to cancelled.
    /// Returns false if the request is no longer queued, including after acquisition.
    @discardableResult
    public func cancel() -> Bool {
        guard let request = owner.value?.removeScheduledCallback(id: ObjectIdentifier(self)) else {
            return false
        }
        resolve(.cancelled)
        // Release the removed request's captured input outside the session gate.
        withExtendedLifetime(request) {}
        return true
    }

    func resolve(_ outcome: ScheduledCallbackOutcome<Output>) {
        state.withLock { $0 = outcome }
    }
}

typealias ScheduledCallbackAction = @Sendable () -> Void

struct PendingCallbackDelivery: Sendable {
    // The acquire and retire actions keep this receipt alive while the request is queued.
    let id: ObjectIdentifier
    let deadline: Duration
    /// Acquires the closure under the session gate and returns work to do after unlocking.
    let acquire: @Sendable () -> ScheduledCallbackAction
    let retire: ScheduledCallbackAction
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
