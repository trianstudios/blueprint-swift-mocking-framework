/// The outcome once a registered answer sequence reaches its final step.
public enum StubSequencePolicy: Sendable {
    /// Report exhaustion on the next matching call.
    case finite
    /// Continue using the final step.
    case repeatLast
    /// Start the sequence again after the final step.
    case cycle
}

enum PlannedAnswer<Answer: Sendable>: Sendable {
    case single(Answer)
    case sequence([Answer], StubSequencePolicy)

    func publish() -> PublishedAnswer<Answer> {
        switch self {
        case .single(let answer): .single(answer)
        case .sequence(let answers, let policy):
            .sequence(AnswerSequence(answers, policy: policy))
        }
    }
}

enum PublishedAnswer<Answer: Sendable>: Sendable {
    case single(Answer)
    case sequence(AnswerSequence<Answer>)

    func reserve() -> Answer? {
        switch self {
        case .single(let answer): answer
        case .sequence(let sequence): sequence.reserve()
        }
    }
}

/// A rule cursor belongs to one installed endpoint revision, never to a reusable plan.
final class AnswerSequence<Answer: Sendable>: Sendable {
    private let steps: [Answer]
    private let policy: StubSequencePolicy
    private let nextIndex = CriticalState(0)

    init(_ steps: [Answer], policy: StubSequencePolicy) {
        precondition(!steps.isEmpty, "An answer sequence needs at least one step")
        self.steps = steps
        self.policy = policy
    }

    func reserve() -> Answer? {
        let count = steps.count
        let policy = self.policy
        let index = nextIndex.withLock { index -> Int? in
            guard index < count else { return nil }
            let reserved = index
            switch policy {
            case .finite:
                index += 1
            case .repeatLast:
                index = min(index + 1, count - 1)
            case .cycle:
                index = index + 1 == count ? 0 : index + 1
            }
            return reserved
        }
        // The transaction updates an integer only. The returned answer is used outside the lock.
        return index.map { steps[$0] }
    }
}
