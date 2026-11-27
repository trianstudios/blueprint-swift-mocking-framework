private typealias ConsumingSyncAnswer<Input: ~Copyable, Output: Sendable> =
    @Sendable (consuming Input) -> Output

public struct ConsumingSyncConfiguration<Input: ~Copyable, Metadata: Sendable, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<Metadata, ConsumingSyncAnswer<Input, Output>>]
}

public final class ConsumingSyncStubbing<Input: ~Copyable, Metadata: Sendable, Output: Sendable> {
    private let builder = EffectRulesBuilder<Metadata, ConsumingSyncAnswer<Input, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<Metadata>) -> ConsumingSyncStub<Input, Metadata, Output> {
        ConsumingSyncStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: Matcher<Metadata>, _ answer: @escaping ConsumingSyncAnswer<Input, Output>) {
        builder.add(matcher, answer)
    }

    public func finish() -> ConsumingSyncConfiguration<Input, Metadata, Output> {
        ConsumingSyncConfiguration(rules: builder.finish())
    }
}

public struct ConsumingSyncStub<Input: ~Copyable, Metadata: Sendable, Output: Sendable> {
    fileprivate let owner: ConsumingSyncStubbing<Input, Metadata, Output>
    fileprivate let matcher: Matcher<Metadata>

    public func willReturn(_ output: Output) {
        willAnswer { (_: consuming Input) in output }
    }

    /// Transfers the original input into the winning synchronous answer.
    public func willAnswer(_ answer: @escaping @Sendable (consuming Input) -> Output) {
        owner.add(matcher, answer)
    }
}

public struct ConsumingSyncVerification<Metadata: Sendable>: Sendable {
    fileprivate let journal: Journal<ProjectedFields<Metadata, Void>>
    fileprivate let matcher: Matcher<Metadata>
    fileprivate let phase: CallPhase

    /// Reads a fresh projection snapshot. A matching phase with a pending
    /// projection makes the assertion incomplete, even for a zero-count check.
    public func wasCalled(_ count: CallCount) -> ProjectedVerificationResult<Metadata> {
        ProjectedInvocationHistory(journal.snapshot()).verify(count, matchingArgument: matcher, phase: phase)
    }
}

/// Borrows the input to obtain metadata, then moves the input once into the
/// winning answer. Shared history retains the projected metadata only.
public final class ConsumingSyncEndpoint<Input: ~Copyable, Metadata: Sendable, Output: Sendable>: Sendable {
    private let configuration: ConsumingSyncConfiguration<Input, Metadata, Output>
    private let projectingInput: @Sendable (borrowing Input) -> Metadata
    private let journal: Journal<ProjectedFields<Metadata, Void>>

    public init(
        id: EndpointID, configuration: ConsumingSyncConfiguration<Input, Metadata, Output>,
        projectingInput: @escaping @Sendable (borrowing Input) -> Metadata,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()
    ) {
        self.configuration = configuration
        self.projectingInput = projectingInput
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ input: consuming Input, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(.init(argument: .pending, result: .pending)) else {
            discardInput(consume input)
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: nil)
        }
        let metadata = projectingInput(input)
        let argument = ProjectedValue.value(metadata)
        journal.update(admission, replacing: .init(argument: argument, result: .pending))

        guard let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(metadata) }) else {
            discardInput(consume input)
            journal.complete(admission, phase: .terminated, replacing: .init(argument: argument, result: .unavailable))
            fatalError(journal.reportMissingCall(admission, source: source).message)
        }
        let result = rule.answer(consume input)
        journal.complete(admission, phase: .returned, replacing: .init(argument: argument, result: .value(())))
        return result
    }

    public func verification(
        matching matcher: Matcher<Metadata>, phase: CallPhase = .admitted
    ) -> ConsumingSyncVerification<Metadata> {
        ConsumingSyncVerification(journal: journal, matcher: matcher, phase: phase)
    }

    private func discardInput(_ input: consuming Input) {}
}
