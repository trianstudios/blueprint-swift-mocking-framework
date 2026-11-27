private typealias OwnedSyncFactory<Input: Sendable, Output: ~Copyable> = @Sendable (Input) -> Output

public struct OwnedSyncConfiguration<Input: Sendable, Output: ~Copyable>: Sendable {
    fileprivate let rules: [Rule<Input, OwnedSyncFactory<Input, Output>>]
}

public final class OwnedSyncStubbing<Input: Sendable, Output: ~Copyable> {
    private let builder = EffectRulesBuilder<Input, OwnedSyncFactory<Input, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> OwnedSyncStub<Input, Output> {
        OwnedSyncStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: Matcher<Input>, _ factory: @escaping OwnedSyncFactory<Input, Output>) {
        builder.add(matcher, factory)
    }

    public func finish() -> OwnedSyncConfiguration<Input, Output> {
        OwnedSyncConfiguration(rules: builder.finish())
    }
}

public struct OwnedSyncStub<Input: Sendable, Output: ~Copyable> {
    fileprivate let owner: OwnedSyncStubbing<Input, Output>
    fileprivate let matcher: Matcher<Input>

    /// Runs the factory once per matching invocation and delivers its owned result to the caller.
    public func willProduce(_ factory: @escaping @Sendable (Input) -> Output) {
        owner.add(matcher, factory)
    }
}

/// Journals Sendable arguments and lifecycle metadata. Each factory return
/// moves straight to the caller.
public final class OwnedSyncEndpoint<Input: Sendable, Output: ~Copyable>: Sendable {
    private let configuration: OwnedSyncConfiguration<Input, Output>
    private let journal: Journal<Input>

    public init(id: EndpointID, configuration: OwnedSyncConfiguration<Input, Output>,
                failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(input) else {
            fatalError(journal.reportFinishedCall(source: source, terminating: true).message)
        }
        guard let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) else {
            fatalError(journal.reportMissingCall(admission, phase: .terminated, source: source).message)
        }
        let output = rule.answer(input)
        journal.complete(admission, phase: .returned)
        return output
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted)
        -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }
}
