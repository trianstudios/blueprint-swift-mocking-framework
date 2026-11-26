/// A matcher evaluated on the main actor. Its input and captures may be actor-local values.
@MainActor
public struct MainActorMatcher<Input> {
    private let predicate: @MainActor (Input) -> Bool

    public init(_ predicate: @escaping @MainActor (Input) -> Bool) {
        self.predicate = predicate
    }

    public func matches(_ input: Input) -> Bool { predicate(input) }

    public static var any: Self { Self { _ in true } }
}

extension MainActorMatcher where Input: Equatable {
    public static func equal(_ expected: Input) -> Self { Self { $0 == expected } }
}

/// An invocation with input retained on the main actor.
@MainActor
public struct MainActorInvocation<Input> {
    public let id: UInt64
    public let input: Input
    public fileprivate(set) var phase: CallPhase
}

@MainActor
private final class MainActorJournal<Input> {
    private let endpoint: EndpointID
    private let reporter: FailureReporter
    private(set) var calls: [MainActorInvocation<Input>] = []

    init(endpoint: EndpointID, reporter: FailureReporter) {
        self.endpoint = endpoint
        self.reporter = reporter
    }

    func begin(_ input: Input) -> UInt64 {
        let id = UInt64(calls.count) + 1
        calls.append(MainActorInvocation(id: id, input: input, phase: .admitted))
        return id
    }

    func complete(_ id: UInt64, phase: CallPhase) {
        calls[Int(id - 1)].phase = phase
    }

    @discardableResult
    func unexpectedCall(_ id: UInt64, phase: CallPhase, source: SourceLocation) -> MockIssue {
        complete(id, phase: phase)
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint,
                              message: "No matching stub for \(endpoint.rawValue)",
                              source: source, watermark: id)
        reporter.report(issue)
        return issue
    }

    func reportCountMismatch(_ message: String, watermark: UInt64, source: SourceLocation) {
        reporter.report(MockIssue(kind: .verificationFailed, endpoint: endpoint,
                                  message: message, source: source, watermark: watermark))
    }
}

/// Counts a snapshot on the main actor before running the caller's matcher.
@MainActor
public struct MainActorVerification<Input> {
    fileprivate let journal: MainActorJournal<Input>
    fileprivate let matcher: MainActorMatcher<Input>
    fileprivate let phase: CallPhase

    @discardableResult
    public func wasCalled(_ count: CallCount, fileID: String = #fileID,
                          staticFilePath: StaticString = #filePath, line: Int = #line,
                          column: Int = #column) -> VerificationResult {
        verifyCount(count, source: SourceLocation(fileID: fileID, staticFilePath: staticFilePath,
                                                  line: line, column: column))
    }

    @discardableResult
    public func wasCalled(_ count: CallCount, fileID: String = #fileID,
                          filePath: String, line: Int = #line,
                          column: Int = #column) -> VerificationResult {
        verifyCount(count, source: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    private func verifyCount(_ count: CallCount, source: @autoclosure () -> SourceLocation) -> VerificationResult {
        let snapshot = journal.calls
        let watermark = UInt64(snapshot.count)
        let ids = snapshot.lazy.filter {
            (phase == .admitted || $0.phase == phase) && matcher.matches($0.input)
        }.map(\.id)
        let invocationIDs = Array(ids)
        let observed = invocationIDs.count
        let failure = count.failureMessage(observed: observed)
        if let failure {
            journal.reportCountMismatch(failure, watermark: watermark, source: source())
        }
        return VerificationResult(passed: failure == nil, observed: observed,
                                  watermark: watermark, invocationIDs: invocationIDs)
    }
}

@MainActor
private struct MainActorRule<Input, Answer> {
    let matcher: MainActorMatcher<Input>
    let answer: Answer
}

@MainActor
private final class MainActorRuleBuilder<Input, Answer> {
    private var rules: [MainActorRule<Input, Answer>] = []
    private var finished = false

    func add(_ matcher: MainActorMatcher<Input>, answer: Answer) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(MainActorRule(matcher: matcher, answer: answer))
    }

    func finish() -> [MainActorRule<Input, Answer>] {
        precondition(!finished, "Setup is already published")
        finished = true
        return rules
    }
}

private typealias MainActorSyncAnswer<Input, Output> = @MainActor (Input) -> Output
// Store a Result to backdeploy the typed-throwing registration API.
private typealias MainActorAsyncAnswer<Input, Output, Failure: Error> =
    @MainActor (Input) async -> Result<Output, Failure>

@MainActor
public struct MainActorSyncConfiguration<Input, Output> {
    fileprivate let rules: [MainActorRule<Input, MainActorSyncAnswer<Input, Output>>]
}

@MainActor
public final class MainActorSyncStubbing<Input, Output> {
    private let builder = MainActorRuleBuilder<Input, MainActorSyncAnswer<Input, Output>>()

    public init() {}

    public func matching(_ matcher: MainActorMatcher<Input>) -> MainActorSyncStub<Input, Output> {
        MainActorSyncStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: MainActorMatcher<Input>,
                         _ answer: @escaping @MainActor (Input) -> Output) {
        builder.add(matcher, answer: answer)
    }

    public func finish() -> MainActorSyncConfiguration<Input, Output> {
        MainActorSyncConfiguration(rules: builder.finish())
    }
}

@MainActor
public struct MainActorSyncStub<Input, Output> {
    fileprivate let owner: MainActorSyncStubbing<Input, Output>
    fileprivate let matcher: MainActorMatcher<Input>

    public func willReturn(_ output: Output) { owner.add(matcher) { _ in output } }

    public func willAnswer(_ answer: @escaping @MainActor (Input) -> Output) {
        owner.add(matcher, answer)
    }
}

@MainActor
public final class MainActorSyncEndpoint<Input, Output> {
    private let configuration: MainActorSyncConfiguration<Input, Output>
    private let journal: MainActorJournal<Input>

    public init(id: EndpointID, configuration: MainActorSyncConfiguration<Input, Output>,
                failureReporter: FailureReporter) {
        self.configuration = configuration
        self.journal = MainActorJournal(endpoint: id, reporter: failureReporter)
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        let id = journal.begin(input)
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            let result = rule.answer(input)
            journal.complete(id, phase: .returned)
            return result
        }
        let issue = journal.unexpectedCall(id, phase: .terminated, source: source)
        fatalError(issue.message)
    }

    public func verification(matching matcher: MainActorMatcher<Input>,
                             phase: CallPhase = .admitted) -> MainActorVerification<Input> {
        MainActorVerification(journal: journal, matcher: matcher, phase: phase)
    }

    public var invocations: [MainActorInvocation<Input>] { journal.calls }
}

@MainActor
public struct MainActorAsyncThrowingConfiguration<Input, Output, Failure: Error> {
    fileprivate let rules: [MainActorRule<Input, MainActorAsyncAnswer<Input, Output, Failure>>]
}

@MainActor
public final class MainActorAsyncThrowingStubbing<Input, Output, Failure: Error> {
    private let builder = MainActorRuleBuilder<Input, MainActorAsyncAnswer<Input, Output, Failure>>()

    public init() {}

    public func matching(_ matcher: MainActorMatcher<Input>) -> MainActorAsyncThrowingStub<Input, Output, Failure> {
        MainActorAsyncThrowingStub(owner: self, matcher: matcher)
    }

    fileprivate func add(_ matcher: MainActorMatcher<Input>,
                         _ answer: @escaping MainActorAsyncAnswer<Input, Output, Failure>) {
        builder.add(matcher, answer: answer)
    }

    public func finish() -> MainActorAsyncThrowingConfiguration<Input, Output, Failure> {
        MainActorAsyncThrowingConfiguration(rules: builder.finish())
    }
}

@MainActor
public struct MainActorAsyncThrowingStub<Input, Output, Failure: Error> {
    fileprivate let owner: MainActorAsyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: MainActorMatcher<Input>

    public func willReturn(_ output: Output) { owner.add(matcher) { _ in .success(output) } }

    public func willThrow(_ error: Failure) {
        owner.add(matcher) { _ in .failure(error) }
    }

    public func willAnswer(_ answer: @escaping @MainActor (Input) async throws(Failure) -> Output) {
        owner.add(matcher) { input in
            do throws(Failure) { return .success(try await answer(input)) }
            catch { return .failure(error) }
        }
    }
}

@MainActor
public final class MainActorAsyncThrowingEndpoint<Input, Output, Failure: Error> {
    private let configuration: MainActorAsyncThrowingConfiguration<Input, Output, Failure>
    private let journal: MainActorJournal<Input>
    private let failureMapping: (@MainActor (MockIssue) -> Failure)?

    public init(id: EndpointID, configuration: MainActorAsyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                failureMapping: (@MainActor (MockIssue) -> Failure)? = nil) {
        self.configuration = configuration
        self.journal = MainActorJournal(endpoint: id, reporter: failureReporter)
        self.failureMapping = failureMapping
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async throws(Failure) -> Output {
        let id = journal.begin(input)
        if let rule = configuration.rules.reversed().first(where: { $0.matcher.matches(input) }) {
            switch await rule.answer(input) {
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
        MainActorVerification(journal: journal, matcher: matcher, phase: phase)
    }

    public var invocations: [MainActorInvocation<Input>] { journal.calls }
}
