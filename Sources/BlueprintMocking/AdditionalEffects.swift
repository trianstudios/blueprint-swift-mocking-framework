/// The default error for an unstubbed ordinary throwing requirement.
public struct UnexpectedInvocationError: Error, CustomStringConvertible {
    public let issue: MockIssue

    public init(issue: MockIssue) {
        self.issue = issue
    }

    public var description: String { issue.message }
}

final class EffectRulesBuilder<Input: Sendable, Answer: Sendable> {
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

/// One immediate, typed result or computation in a synchronous throwing sequence.
public struct SyncThrowingSequenceStep<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let answer: SyncThrowingAnswer<Input, Output, Failure>

    public static func returning(_ output: Output) -> Self {
        Self(answer: { _ in .success(output) })
    }

    public static func throwing(_ failure: Failure) -> Self {
        Self(answer: { _ in .failure(failure) })
    }

    public static func answering(_ body: @escaping @Sendable (Input) throws(Failure) -> Output) -> Self {
        Self(answer: { input in
            do throws(Failure) { return .success(try body(input)) }
            catch { return .failure(error) }
        })
    }
}

public struct SyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [Rule<Input, PlannedAnswer<SyncThrowingAnswer<Input, Output, Failure>>>]

    fileprivate func publish() -> PublishedSyncThrowingConfiguration<Input, Output, Failure> {
        PublishedSyncThrowingConfiguration(rules: rules.map { rule in
            Rule(matcher: rule.matcher, answer: rule.answer.publish())
        })
    }
}

private struct PublishedSyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let rules: [Rule<Input, PublishedAnswer<SyncThrowingAnswer<Input, Output, Failure>>>]

    func forkSequences(restarting: Bool) -> Self {
        Self(rules: rules.map { rule in
            Rule(matcher: rule.matcher, answer: rule.answer.forkSequence(restarting: restarting))
        })
    }
}

public final class SyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let builder = EffectRulesBuilder<Input, PlannedAnswer<SyncThrowingAnswer<Input, Output, Failure>>>()

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
        owner.builder.add(matcher, .single(SyncThrowingSequenceStep<Input, Output, Failure>.returning(output).answer))
    }

    public func willThrow(_ error: Failure) {
        owner.builder.add(matcher, .single(SyncThrowingSequenceStep<Input, Output, Failure>.throwing(error).answer))
    }

    public func willAnswer(_ answer: @escaping @Sendable (Input) throws(Failure) -> Output) {
        owner.builder.add(matcher, .single(SyncThrowingSequenceStep<Input, Output, Failure>.answering(answer).answer))
    }

    /// Reserves one step per matching call. An exhausted winner reports a failure.
    public func willSequence(
        _ first: SyncThrowingSequenceStep<Input, Output, Failure>,
        _ remaining: SyncThrowingSequenceStep<Input, Output, Failure>...,
        policy: StubSequencePolicy = .finite
    ) {
        owner.builder.add(matcher, .sequence([first.answer] + remaining.map(\.answer), policy))
    }
}

/// A real implementation for a checked Sendable synchronous throwing endpoint.
public struct SyncThrowingForwarding<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let answer: SyncThrowingAnswer<Input, Output, Failure>

    public init(_ body: @escaping @Sendable (Input) throws(Failure) -> Output) {
        self.answer = { input in
            do throws(Failure) { return .success(try body(input)) }
            catch { return .failure(error) }
        }
    }
}

public final class SyncThrowingEndpoint<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let session: MockSession
    private let journal: ConfiguredJournal<Input, PublishedSyncThrowingConfiguration<Input, Output, Failure>>
    private let forwarding: SyncThrowingForwarding<Input, Output, Failure>?
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?

    public convenience init(
        id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        failureMapping: (@Sendable (MockIssue) -> Failure)? = nil
    ) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: nil, failureMapping: failureMapping)
    }

    /// Calls the real implementation on a stub miss if supplied.
    public init(id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                forwarding: SyncThrowingForwarding<Input, Output, Failure>?,
                failureMapping: (@Sendable (MockIssue) -> Failure)? = nil) {
        self.session = scope.session
        self.journal = ConfiguredJournal(
            endpoint: id, reporter: failureReporter, scope: scope, configuration: configuration.publish(),
            forkConfigurationOnReset: { $0.forkSequences(restarting: $1) }
        )
        self.forwarding = forwarding
        self.failureMapping = failureMapping
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) throws(Failure) -> Output {
        guard let (admission, configuration) = journal.admit(input) else {
            let issue = journal.reportFinishedCall(source: source, terminating: failureMapping == nil)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        }
        defer { withExtendedLifetime(configuration) {} }

        let outcome: Result<Output, Failure>
        let origin: CallOrigin?
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            guard let answer = rule.answer.reserve(in: session) else {
                return try resolveUnanswered(admission, source: source, exhaustedSequence: true)
            }
            origin = nil
            outcome = answer(input)
        } else if let forwarding {
            origin = .forwarded
            outcome = forwarding.answer(input)
        } else {
            return try resolveUnanswered(admission, source: source, exhaustedSequence: false)
        }

        switch outcome {
        case .success(let result):
            journal.complete(admission, phase: .returned, origin: origin)
            return result
        case .failure(let error):
            journal.complete(admission, phase: .threw, origin: origin)
            throw error
        }
    }

    private func resolveUnanswered(
        _ admission: JournalAdmission, source: SourceLocation, exhaustedSequence: Bool
    ) throws(Failure) -> Output {
        let phase: CallPhase? = failureMapping == nil ? .terminated : nil
        let issue = exhaustedSequence
            ? journal.reportExhaustedSequence(admission, phase: phase, source: source)
            : journal.reportMissingCall(admission, phase: phase, source: source)
        if let failureMapping {
            let error = failureMapping(issue)
            journal.complete(admission, phase: .threw)
            throw error
        }
        fatalError(issue.message)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted,
                             origin: CallOrigin?) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}

extension SyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  forwarding: nil, failureMapping: { UnexpectedInvocationError(issue: $0) })
    }

    public convenience init(id: EndpointID, configuration: SyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
                            forwarding: SyncThrowingForwarding<Input, Output, Failure>?) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  forwarding: forwarding, failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

extension AsyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` for an unstubbed ordinary throwing call.
    public convenience init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  forwarding: nil, failureMapping: { UnexpectedInvocationError(issue: $0) })
    }

    public convenience init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                            failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
                            forwarding: AsyncThrowingForwarding<Input, Output, Failure>?) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter, scope: scope,
                  forwarding: forwarding, failureMapping: { UnexpectedInvocationError(issue: $0) })
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
    private let forwarding: AsyncNonthrowingAnswer<Input, Output>?
    private let fallback: (@Sendable (MockIssue) -> Output)?

    /// Reports an unstubbed call before invoking the failure fallback.
    public convenience init(
        id: EndpointID, configuration: AsyncConfiguration<Input, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: nil, fallback: fallback)
    }

    /// Calls the real implementation on a stub miss if supplied.
    public init(id: EndpointID, configuration: AsyncConfiguration<Input, Output>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                forwarding: (@Sendable (Input) async -> Output)?,
                fallback: (@Sendable (MockIssue) -> Output)? = nil) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.forwarding = forwarding
        self.fallback = fallback
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        let rule = configuration.rules.reversed().first { $0.matcher.matches(input) }
        if let answer = rule?.answer ?? forwarding {
            let result = await answer(input)
            journal.complete(admission, phase: .returned, origin: rule == nil ? .forwarded : nil)
            return result
        }
        return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted,
                             origin: CallOrigin?) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}
