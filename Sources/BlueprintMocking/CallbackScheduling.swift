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
    /// The capture was retired or was no longer owned when delivery came due.
    case unavailable
}

extension ScheduledCallbackOutcome: Equatable where Output: Equatable {}

/// A receipt for a scheduled callback. Reading it does not run or reschedule the callback.
public final class ScheduledCallbackDelivery<Output: Sendable>: Sendable {
    private let state = CriticalState<ScheduledCallbackOutcome<Output>>(.pending)

    init() {}

    public var outcome: ScheduledCallbackOutcome<Output> {
        state.withLock { $0 }
    }

    func resolve(_ outcome: ScheduledCallbackOutcome<Output>) {
        state.withLock { $0 = outcome }
    }
}

typealias ScheduledCallbackAction = @Sendable () -> Void

struct PendingCallbackDelivery: Sendable {
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
