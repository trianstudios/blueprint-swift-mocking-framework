// Store Result so the private rule representation supports the original OS floors.
private typealias MainActorSyncThrowingAnswer<Input, Output, Failure: Error> =
    @MainActor (Input) -> Result<Output, Failure>

@MainActor
public struct MainActorSyncThrowingConfiguration<Input, Output, Failure: Error> {
    fileprivate let rules: [MainActorRule<Input, MainActorSyncThrowingAnswer<Input, Output, Failure>>]
}

@MainActor
public final class MainActorSyncThrowingStubbing<Input, Output, Failure: Error> {
    fileprivate let builder = MainActorRuleBuilder<Input, MainActorSyncThrowingAnswer<Input, Output, Failure>>()

    public init() {}

    public func matching(_ matcher: MainActorMatcher<Input>) -> MainActorSyncThrowingStub<Input, Output, Failure> {
        MainActorSyncThrowingStub(owner: self, matcher: matcher)
    }

    public func finish() -> MainActorSyncThrowingConfiguration<Input, Output, Failure> {
        MainActorSyncThrowingConfiguration(rules: builder.finish())
    }
}

@MainActor
public struct MainActorSyncThrowingStub<Input, Output, Failure: Error> {
    fileprivate let owner: MainActorSyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: MainActorMatcher<Input>

    public func willReturn(_ output: Output) {
        owner.builder.add(matcher, answer: { _ in .success(output) })
    }

    public func willThrow(_ error: Failure) {
        owner.builder.add(matcher, answer: { _ in .failure(error) })
    }

    public func willAnswer(_ answer: @escaping @MainActor (Input) throws(Failure) -> Output) {
        owner.builder.add(matcher) { input in
            do throws(Failure) { return .success(try answer(input)) }
            catch { return .failure(error) }
        }
    }
}

@MainActor
public final class MainActorSyncThrowingEndpoint<Input, Output, Failure: Error> {
    private let configuration: MainActorSyncThrowingConfiguration<Input, Output, Failure>
    private let journal: MainActorJournal<Input>
    private let failureMapping: (@MainActor (MockIssue) -> Failure)?

    public init(id: EndpointID, configuration: MainActorSyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                failureMapping: (@MainActor (MockIssue) -> Failure)? = nil) {
        self.configuration = configuration
        self.journal = MainActorJournal(endpoint: id, reporter: failureReporter)
        self.failureMapping = failureMapping
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) throws(Failure) -> Output {
        let id = journal.begin(input)
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            switch rule.answer(input) {
            case .success(let result):
                journal.complete(id, phase: .returned)
                return result
            case .failure(let error):
                journal.complete(id, phase: .threw)
                throw error
            }
        }
        if let failureMapping {
            let issue = journal.unexpectedCall(id, phase: .threw, source: source)
            throw failureMapping(issue)
        }
        let issue = journal.unexpectedCall(id, phase: .terminated, source: source)
        fatalError(issue.message)
    }

    public func verification(matching matcher: MainActorMatcher<Input>,
                             phase: CallPhase = .admitted) -> MainActorVerification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public var invocations: [MainActorInvocation<Input>] { journal.calls }
}

extension MainActorSyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: MainActorSyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

extension MainActorAsyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: MainActorAsyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

private typealias MainActorAsyncNonthrowingAnswer<Input, Output> = @MainActor (Input) async -> Output

@MainActor
public struct MainActorAsyncConfiguration<Input, Output> {
    fileprivate let rules: [MainActorRule<Input, MainActorAsyncNonthrowingAnswer<Input, Output>>]
}

@MainActor
public final class MainActorAsyncStubbing<Input, Output> {
    fileprivate let builder = MainActorRuleBuilder<Input, MainActorAsyncNonthrowingAnswer<Input, Output>>()

    public init() {}

    public func matching(_ matcher: MainActorMatcher<Input>) -> MainActorAsyncStub<Input, Output> {
        MainActorAsyncStub(owner: self, matcher: matcher)
    }

    public func finish() -> MainActorAsyncConfiguration<Input, Output> {
        MainActorAsyncConfiguration(rules: builder.finish())
    }
}

@MainActor
public struct MainActorAsyncStub<Input, Output> {
    fileprivate let owner: MainActorAsyncStubbing<Input, Output>
    fileprivate let matcher: MainActorMatcher<Input>

    public func willReturn(_ output: Output) {
        owner.builder.add(matcher, answer: { _ in output })
    }

    public func willAnswer(_ answer: @escaping @MainActor (Input) async -> Output) {
        owner.builder.add(matcher, answer: answer)
    }
}

@MainActor
public final class MainActorAsyncEndpoint<Input, Output> {
    private let configuration: MainActorAsyncConfiguration<Input, Output>
    private let journal: MainActorJournal<Input>
    private let fallback: (@MainActor (MockIssue) -> Output)?

    /// Reports an unstubbed call before invoking the fallback. Without one, it terminates after reporting.
    public init(id: EndpointID, configuration: MainActorAsyncConfiguration<Input, Output>,
                failureReporter: FailureReporter,
                fallback: (@MainActor (MockIssue) -> Output)? = nil) {
        self.configuration = configuration
        self.journal = MainActorJournal(endpoint: id, reporter: failureReporter)
        self.fallback = fallback
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async -> Output {
        let id = journal.begin(input)
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            let result = await rule.answer(input)
            journal.complete(id, phase: .returned)
            return result
        }
        return journal.resolveMissingNonthrowingCall(id, source: source, fallback: fallback)
    }

    public func verification(matching matcher: MainActorMatcher<Input>,
                             phase: CallPhase = .admitted) -> MainActorVerification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public var invocations: [MainActorInvocation<Input>] { journal.calls }
}
