/// The default error for an unstubbed ordinary throwing requirement.
public struct UnexpectedInvocationError: Error, CustomStringConvertible {
    public let issue: MockIssue

    public init(issue: MockIssue) {
        self.issue = issue
    }

    public var description: String { issue.message }
}

private final class EffectRulesBuilder<Input: Sendable, Answer: Sendable> {
    private var rules: [Rule<Input, Answer>] = []
    private var finished = false

    func add(_ matcher: Matcher<Input>, _ answer: Answer) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: answer))
    }

    func finish() -> [Rule<Input, Answer>] {
        precondition(!finished, "Setup is already published")
        finished = true
        return rules
    }
}

// Store Result so the private rule representation supports the original OS floors.
private typealias SyncThrowingAnswer<Input, Output, Failure: Error> =
    @Sendable (Input) -> Result<Output, Failure>

public struct SyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [Rule<Input, SyncThrowingAnswer<Input, Output, Failure>>]
}

public final class SyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let builder = EffectRulesBuilder<Input, SyncThrowingAnswer<Input, Output, Failure>>()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> SyncThrowingStub<Input, Output, Failure> {
        SyncThrowingStub(owner: self, matcher: matcher)
    }

    public func finish() -> SyncThrowingConfiguration<Input, Output, Failure> {
        SyncThrowingConfiguration(rules: builder.finish())
    }
}

public struct SyncThrowingStub<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let owner: SyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: Matcher<Input>

    public func willReturn(_ output: Output) {
        owner.builder.add(matcher) { _ in .success(output) }
    }

    public func willThrow(_ error: Failure) {
        owner.builder.add(matcher) { _ in .failure(error) }
    }

    public func willAnswer(_ answer: @escaping @Sendable (Input) throws(Failure) -> Output) {
        owner.builder.add(matcher) { input in
            do throws(Failure) { return .success(try answer(input)) }
            catch { return .failure(error) }
        }
    }
}

public final class SyncThrowingEndpoint<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let configuration: SyncThrowingConfiguration<Input, Output, Failure>
    private let journal: Journal<Input>
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?

    public init(id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                failureMapping: (@Sendable (MockIssue) -> Failure)? = nil) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.failureMapping = failureMapping
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) throws(Failure) -> Output {
        guard let admission = journal.begin(input) else {
            let issue = journal.reportFinishedCall(source: source)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        }
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            switch rule.answer(input) {
            case .success(let result):
                journal.complete(admission, phase: .returned)
                return result
            case .failure(let error):
                journal.complete(admission, phase: .threw)
                throw error
            }
        }
        if let failureMapping {
            let issue = journal.reportMissingCall(admission, source: source)
            let error = failureMapping(issue)
            journal.complete(admission, phase: .threw)
            throw error
        }
        let issue = journal.reportMissingCall(admission, phase: .terminated, source: source)
        fatalError(issue.message)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}

extension SyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

extension AsyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

private typealias AsyncNonthrowingAnswer<Input, Output> = @Sendable (Input) async -> Output

public struct AsyncConfiguration<Input: Sendable, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<Input, AsyncNonthrowingAnswer<Input, Output>>]
}

public final class AsyncStubbing<Input: Sendable, Output: Sendable> {
    fileprivate let builder = EffectRulesBuilder<Input, AsyncNonthrowingAnswer<Input, Output>>()

    public init() {}

    public func matching(_ matcher: Matcher<Input>) -> AsyncStub<Input, Output> {
        AsyncStub(owner: self, matcher: matcher)
    }

    public func finish() -> AsyncConfiguration<Input, Output> {
        AsyncConfiguration(rules: builder.finish())
    }
}

public struct AsyncStub<Input: Sendable, Output: Sendable> {
    fileprivate let owner: AsyncStubbing<Input, Output>
    fileprivate let matcher: Matcher<Input>

    public func willReturn(_ output: Output) {
        owner.builder.add(matcher) { _ in output }
    }

    public func willAnswer(_ answer: @escaping @Sendable (Input) async -> Output) {
        owner.builder.add(matcher, answer)
    }
}

public final class AsyncEndpoint<Input: Sendable, Output: Sendable>: Sendable {
    private let configuration: AsyncConfiguration<Input, Output>
    private let journal: Journal<Input>
    private let fallback: (@Sendable (MockIssue) -> Output)?

    /// Reports an unstubbed call before invoking the fallback. Without one, it terminates after reporting.
    public init(id: EndpointID, configuration: AsyncConfiguration<Input, Output>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                fallback: (@Sendable (MockIssue) -> Output)? = nil) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.fallback = fallback
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            let result = await rule.answer(input)
            journal.complete(admission, phase: .returned)
            return result
        }
        return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}
