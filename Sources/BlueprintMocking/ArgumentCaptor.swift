/// A projected argument and the admission that selected its capturing rule.
public struct ArgumentCapture<Value: Sendable>: Sendable {
    public let invocation: SessionEvent
    public let value: Value
}

/// A session-bound capture list for rules that explicitly opt in.
///
/// A session history reset clears its live captures. Previously returned arrays retain
/// their values. Supply a value projection for capture-time data, since a Sendable
/// reference can still change after publication.
public final class ArgumentCaptor<Value: Sendable>: Sendable {
    fileprivate let session: MockSession
    private let storage = CriticalState<[ArgumentCapture<Value>]>([])

    public init(session: MockSession) {
        self.session = session
        session.register(self)
    }

    /// Returns a frozen list ordered by admission, even when projections finish out of order.
    public var captures: [ArgumentCapture<Value>] {
        let snapshot = session.withLock { _ in storage.withLock { $0 } }
        return snapshot.sorted { $0.invocation.ordinal < $1.invocation.ordinal }
    }

    fileprivate func publish(_ capture: ArgumentCapture<Value>) {
        session.withLock { state in
            guard state.epoch == capture.invocation.epoch else { return }
            storage.withLock { $0.append(capture) }
        }
        // A dropped old-epoch value can run user code during destruction.
        withExtendedLifetime(capture) {}
    }
}

extension ArgumentCaptor: SessionJournalRegistration {
    func discardHistory(restartingSequences _: Bool) -> any Sendable {
        storage.withLock {
            let retired = $0
            $0 = []
            return retired
        }
    }
}

struct WinningRuleCapture<Input: Sendable>: Sendable {
    let sessionID: SessionID
    let publish: @Sendable (Input, SessionEvent) -> Void

    init<Value: Sendable>(
        captor: ArgumentCaptor<Value>, projecting projection: @escaping @Sendable (Input) -> Value
    ) {
        sessionID = captor.session.id
        publish = { input, invocation in
            let value = projection(input)
            captor.publish(ArgumentCapture(invocation: invocation, value: value))
        }
    }
}
