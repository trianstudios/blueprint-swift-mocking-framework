private typealias IsolatedSyncAnswer<ActorParameter: Actor, Output: Sendable> =
    @Sendable (isolated ActorParameter) -> Output

public struct IsolatedSyncConfiguration<ActorParameter: Actor, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<ActorParameter, IsolatedSyncAnswer<ActorParameter, Output>>]
}

public final class IsolatedSyncStubbing<ActorParameter: Actor, Output: Sendable> {
    private let builder = EffectRulesBuilder<ActorParameter, IsolatedSyncAnswer<ActorParameter, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<ActorParameter>) -> IsolatedSyncStub<ActorParameter, Output> {
        IsolatedSyncStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: Matcher<ActorParameter>,
                         _ answer: @escaping IsolatedSyncAnswer<ActorParameter, Output>) {
        builder.add(matcher, answer)
    }

    public func finish() -> IsolatedSyncConfiguration<ActorParameter, Output> {
        IsolatedSyncConfiguration(rules: builder.finish())
    }
}

public struct IsolatedSyncStub<ActorParameter: Actor, Output: Sendable> {
    fileprivate let owner: IsolatedSyncStubbing<ActorParameter, Output>
    fileprivate let matcher: Matcher<ActorParameter>

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    /// The supplied actor is isolated while the synchronous answer runs.
    public func willAnswer(_ answer: @escaping @Sendable (isolated ActorParameter) -> Output) {
        owner.add(matcher, answer)
    }
}

/// Runs answers on the caller's original isolated actor. The journal retains
/// ordinary Sendable actor references for identity verification.
public final class IsolatedSyncEndpoint<ActorParameter: Actor, Output: Sendable>: Sendable {
    private let configuration: IsolatedSyncConfiguration<ActorParameter, Output>
    private let journal: Journal<ActorParameter>

    public init(id: EndpointID, configuration: IsolatedSyncConfiguration<ActorParameter, Output>,
                failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ actor: isolated ActorParameter, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(actor) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: nil)
        }
        guard let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(actor) }) else {
            return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: nil)
        }
        let result = rule.answer(actor)
        journal.complete(admission, phase: .returned)
        return result
    }

    /// Verifies with nonisolated matchers. An identity matcher can compare actor references.
    public func verification(matching matcher: Matcher<ActorParameter>, phase: CallPhase = .admitted)
        -> Verification<ActorParameter> {
        journal.verification(matching: matcher, phase: phase)
    }
}
