private typealias SendingAsyncAnswer<Input, Output> =
    @Sendable (sending Input) async -> sending Output

public struct SendingAsyncConfiguration<Input, Metadata: Sendable, Output>: Sendable {
    fileprivate let rules: [Rule<Metadata, SendingAsyncAnswer<Input, Output>>]
}

public final class SendingAsyncStubbing<Input, Metadata: Sendable, Output> {
    private let builder = EffectRulesBuilder<Metadata, SendingAsyncAnswer<Input, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<Metadata>) -> SendingAsyncStub<Input, Metadata, Output> {
        SendingAsyncStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: Matcher<Metadata>,
                         _ answer: @escaping SendingAsyncAnswer<Input, Output>) {
        builder.add(matcher, answer)
    }

    public func finish() -> SendingAsyncConfiguration<Input, Metadata, Output> {
        SendingAsyncConfiguration(rules: builder.finish())
    }
}

public struct SendingAsyncStub<Input, Metadata: Sendable, Output> {
    fileprivate let owner: SendingAsyncStubbing<Input, Metadata, Output>
    fileprivate let matcher: Matcher<Metadata>

    /// Each call transfers its input to the answer and receives a disconnected result.
    public func willAnswer(_ answer: @escaping @Sendable (sending Input) async -> sending Output) {
        owner.add(matcher, answer)
    }
}

public struct SendingAsyncVerification<Argument: Sendable, Result: Sendable>: Sendable {
    fileprivate let journal: Journal<ProjectedFields<Argument, Result>>
    fileprivate let matcher: Matcher<Argument>
    fileprivate let phase: CallPhase

    /// Verifies matching input snapshots. Pending projections prevent a complete assertion.
    public func wasCalled(_ count: CallCount) -> ProjectedVerificationResult<Argument> {
        projectedHistory().verify(count, matchingArgument: matcher, phase: phase)
    }

    /// Returns all current-epoch projected records for this endpoint.
    public func projectedHistory() -> ProjectedInvocationHistory<Argument, Result> {
        ProjectedInvocationHistory(journal.snapshot())
    }
}

/// Records Sendable projections around an async transfer; no raw input or output enters history.
public final class SendingAsyncEndpoint<Input, Argument: Sendable, Output, Result: Sendable>: Sendable {
    private let configuration: SendingAsyncConfiguration<Input, Argument, Output>
    private let projectInput: @Sendable (Input) -> Argument
    private let projectResult: @Sendable (Output) -> Result
    private let journal: Journal<ProjectedFields<Argument, Result>>

    public init(
        id: EndpointID, configuration: SendingAsyncConfiguration<Input, Argument, Output>,
        projectInput: @escaping @Sendable (Input) -> Argument,
        projectResult: @escaping @Sendable (Output) -> Result,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()
    ) {
        self.configuration = configuration
        self.projectInput = projectInput
        self.projectResult = projectResult
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ input: sending Input, source: SourceLocation = SourceLocation()) async -> sending Output {
        guard let admission = journal.begin(.init(argument: .pending, result: .pending)) else {
            fatalError(journal.reportFinishedCall(source: source, terminating: true).message)
        }
        let metadata = projectInput(input)
        let argument = ProjectedValue.value(metadata)
        journal.update(admission, replacing: .init(argument: argument, result: .pending))

        guard let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(metadata) }) else {
            journal.complete(admission, phase: .terminated, replacing: .init(argument: argument, result: .unavailable))
            fatalError(journal.reportMissingCall(admission, source: source).message)
        }
        let output = await rule.answer(input)
        let result = ProjectedValue.value(projectResult(output))
        journal.complete(admission, phase: .returned, replacing: .init(argument: argument, result: result))
        return output
    }

    public func verification(matching matcher: Matcher<Argument>, phase: CallPhase = .admitted)
        -> SendingAsyncVerification<Argument, Result> {
        SendingAsyncVerification(journal: journal, matcher: matcher, phase: phase)
    }
}
