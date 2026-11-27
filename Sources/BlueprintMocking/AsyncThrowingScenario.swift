/// A guarded transition for one published Sendable async-throwing rule.
public struct AsyncThrowingScenarioTransition<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let source: String
    let guardMatcher: Matcher<Input>
    let reservedState: String
    let answer: AsyncThrowingSequenceStep<Input, Output, Failure>
    let returnedState: String?

    /// Moves to the reserved state before the answer runs. An optional successful
    /// completion transition is ignored if the state version or history epoch
    /// changed, the base rule was replaced, or the owning lexical scope closed.
    public init(
        from source: String, when guardMatcher: Matcher<Input>, reserving reservedState: String,
        answer: AsyncThrowingSequenceStep<Input, Output, Failure>, onReturn returnedState: String? = nil
    ) {
        precondition(!source.isEmpty && !reservedState.isEmpty && returnedState != "",
                     "Scenario state names must not be empty")
        self.source = source
        self.guardMatcher = guardMatcher
        self.reservedState = reservedState
        self.answer = answer
        self.returnedState = returnedState
    }
}

struct AsyncScenarioPlan<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let initial: String
    let transitions: [AsyncThrowingScenarioTransition<Input, Output, Failure>]
    let conflict: Failure
}

private struct AsyncScenarioState: Sendable {
    var name: String
    var version: UInt64 = 0

    mutating func move(to name: String) {
        self.name = name
        version += 1
    }
}

private final class AsyncScenarioCursor: Sendable {
    let state: CriticalState<AsyncScenarioState>

    init(_ state: AsyncScenarioState) { self.state = CriticalState(state) }
}

struct AsyncScenarioCompletion: Sendable {
    fileprivate let cursor: AsyncScenarioCursor
    fileprivate let expectedVersion: UInt64
    fileprivate let returnedState: String

    /// The journal already holds the session gate and confirmed the epoch and revision.
    func commitIfCurrent() {
        cursor.state.withLock { state in
            guard state.version == expectedVersion else { return }
            state.move(to: returnedState)
        }
    }
}

enum AsyncScenarioReservation<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    case reserved(AsyncThrowingSequenceStep<Input, Output, Failure>, AsyncScenarioCompletion?)
    case conflict(Failure)
}

struct PublishedAsyncScenario<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let plan: AsyncScenarioPlan<Input, Output, Failure>
    private let cursor: AsyncScenarioCursor

    init(plan: AsyncScenarioPlan<Input, Output, Failure>) {
        self.init(plan: plan, cursor: AsyncScenarioCursor(AsyncScenarioState(name: plan.initial)))
    }

    private init(plan: AsyncScenarioPlan<Input, Output, Failure>, cursor: AsyncScenarioCursor) {
        self.plan = plan
        self.cursor = cursor
    }

    func fork() -> Self {
        let snapshot = cursor.state.withLock { $0 }
        return Self(plan: plan, cursor: AsyncScenarioCursor(snapshot))
    }

    func reserve(_ input: Input, in session: MockSession) -> AsyncScenarioReservation<Input, Output, Failure> {
        let matching = plan.transitions.reversed().filter { $0.guardMatcher.matches(input) }
        return session.withLock { _ in
            cursor.state.withLock { state in
                guard let selected = matching.first(where: { $0.source == state.name }) else {
                    return .conflict(plan.conflict)
                }
                state.move(to: selected.reservedState)
                let completion = selected.returnedState.map {
                    AsyncScenarioCompletion(cursor: cursor, expectedVersion: state.version, returnedState: $0)
                }
                return .reserved(selected.answer, completion)
            }
        }
    }
}
