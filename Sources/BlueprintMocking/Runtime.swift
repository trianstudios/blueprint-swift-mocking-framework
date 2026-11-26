// A compile-time generated-code/runtime schema marker. This is not a release version.
public enum BlueprintRuntimeSchemaV1 {}

public struct EndpointID: Sendable, Equatable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SourceLocation: Sendable, Equatable {
    public let fileID: String
    public let filePath: String
    public let line: Int
    public let column: Int

    /// The original literal, when available for reporters that require a static path.
    public let staticFilePath: StaticString?

    public init(fileID: String = #fileID, filePath: String, line: Int = #line, column: Int = #column) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        self.staticFilePath = nil
    }

    public init(fileID: String = #fileID, staticFilePath: StaticString = #filePath,
                line: Int = #line, column: Int = #column) {
        self.fileID = fileID
        self.filePath = staticFilePath.description
        self.line = line
        self.column = column
        self.staticFilePath = staticFilePath
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileID == rhs.fileID && lhs.filePath == rhs.filePath
            && lhs.line == rhs.line && lhs.column == rhs.column
    }
}

public struct MockIssue: Sendable {
    public enum Kind: Sendable { case unexpectedCall, verificationFailed, sequenceExhausted }
    public let kind: Kind
    public let endpoint: EndpointID
    public let message: String
    public let source: SourceLocation
    public let watermark: UInt64
}

public struct FailureReporter: Sendable {
    private let body: @Sendable (MockIssue) -> Void
    public init(_ body: @escaping @Sendable (MockIssue) -> Void) { self.body = body }
    public func report(_ issue: MockIssue) { body(issue) }
}

public struct Matcher<Input: Sendable>: Sendable {
    private let body: @Sendable (Input) -> Bool
    public init(_ body: @escaping @Sendable (Input) -> Bool) { self.body = body }
    public func matches(_ input: Input) -> Bool { body(input) }
    public static var any: Self { Self { _ in true } }
}
extension Matcher where Input: Equatable {
    public static func equal(_ expected: Input) -> Self { Self { $0 == expected } }
}

/// The endpoint-local revision that supplied an invocation's immutable stubbing plan.
public struct RuleRevision: Sendable, Equatable {
    public let rawValue: UInt64
}

/// Admission queries include unfinished and throwing calls; terminal phases are explicit.
public enum CallPhase: Sendable, Equatable { case admitted, returned, threw, terminated }
public struct Invocation<Input: Sendable>: Sendable {
    public let id: UInt64
    public fileprivate(set) var input: Input
    public let configurationRevision: RuleRevision
    public let sessionInvocationID: SessionInvocationID
    public let epoch: SessionEpoch
    public fileprivate(set) var phase: CallPhase
}
public struct VerificationResult: Sendable {
    public let passed: Bool
    public let observed: Int
    public let watermark: UInt64
    public let invocationIDs: [UInt64]

    /// The epoch of a session-backed query. Actor-local queries currently have no session.
    public let epoch: SessionEpoch?

    /// The descriptor was created in an earlier epoch and was rejected without evaluating its matcher.
    public let isStale: Bool

    init(passed: Bool, observed: Int, watermark: UInt64, invocationIDs: [UInt64],
         epoch: SessionEpoch? = nil, isStale: Bool = false) {
        self.passed = passed
        self.observed = observed
        self.watermark = watermark
        self.invocationIDs = invocationIDs
        self.epoch = epoch
        self.isStale = isStale
    }
}

struct JournalSnapshot<Input: Sendable>: Sendable {
    let calls: [Invocation<Input>]
    let watermark: UInt64
    let epoch: SessionEpoch
    let isStale: Bool
}

struct JournalAdmission: Sendable {
    let id: UInt64
    let event: SessionEvent
}

private protocol VerificationJournal<Input>: Sendable {
    associatedtype Input: Sendable

    var endpoint: EndpointID { get }
    func snapshot(validating expectedEpoch: SessionEpoch?) -> JournalSnapshot<Input>
    func report(_ issue: MockIssue)
}

fileprivate enum UnansweredCallReason {
    case noMatchingStub
    case exhaustedSequence
}

typealias Journal<Input: Sendable> = ConfiguredJournal<Input, Void>

final class ConfiguredJournal<Input: Sendable, Configuration: Sendable>: VerificationJournal, SessionJournalRegistration {
    private struct State: Sendable {
        var configuration: Configuration
        var revision = RuleRevision(rawValue: 0)
        var nextID: UInt64 = 0
        var calls: [Invocation<Input>] = []
        var issues: [MockIssue] = []
    }

    private let state: CriticalState<State>
    private let scope: MockScope
    let endpoint: EndpointID
    private let reporter: FailureReporter

    init(endpoint: EndpointID, reporter: FailureReporter, scope: MockScope, configuration: Configuration) {
        self.state = CriticalState(State(configuration: configuration))
        self.scope = scope
        self.endpoint = endpoint
        self.reporter = reporter
        scope.session.register(self)
    }

    func admit(_ input: Input) -> (admission: JournalAdmission, configuration: Configuration)? {
        // Lock order is session, then this endpoint. No operation holds two endpoint locks.
        let (result, wake) = scope.session.withLock {
            session -> ((admission: JournalAdmission, configuration: Configuration)?, SessionObservationDelivery?) in
            guard !session.isFinished else { return (nil, nil) }
            let result = state.withLock {
                $0.nextID += 1
                let id = $0.nextID
                let event = session.admit(mockID: scope.id, endpoint: endpoint,
                                          configurationRevision: $0.revision)
                $0.calls.append(Invocation(id: id, input: input, configurationRevision: $0.revision,
                                          sessionInvocationID: event.invocationID, epoch: event.epoch,
                                          phase: .admitted))
                return (JournalAdmission(id: id, event: event), $0.configuration)
            }
            return (result, session.observationWake())
        }
        wake?.publish()
        return result
    }

    func replaceConfiguration(_ configuration: Configuration) -> RuleRevision {
        let (revision, retired) = state.withLock {
            let retired = $0.configuration
            let revision = RuleRevision(rawValue: $0.revision.rawValue + 1)
            $0.configuration = configuration
            $0.revision = revision
            return (revision, retired)
        }
        // A captured object can run user code in deinit.
        withExtendedLifetime(retired) {}
        return revision
    }

    func update(_ admission: JournalAdmission, replacing input: Input) {
        let (retired, wake) = scope.session.withLock { session -> (Input?, SessionObservationDelivery?) in
            guard admission.event.epoch == session.epoch else { return (nil, nil) }
            let retired = state.withLock { history in
                let index = Self.retainedIndex(of: admission, in: history.calls)
                precondition(history.calls[index].phase == .admitted, "Cannot update a completed invocation")
                let previous = history.calls[index].input
                history.calls[index].input = input
                return previous
            }
            return (retired, session.observationWake())
        }
        wake?.publish()
        withExtendedLifetime(retired) {}
    }

    func complete(_ admission: JournalAdmission, phase: CallPhase, replacing input: Input? = nil) {
        let (delivery, wake, retired) = scope.session.withLock { session in
            let ready = session.complete(admission.event.invocationID, phase: phase)
            var retired: Input? = nil
            if admission.event.epoch == session.epoch {
                retired = state.withLock { history -> Input? in
                    let index = Self.retainedIndex(of: admission, in: history.calls)
                    history.calls[index].phase = phase
                    guard let input else { return nil }
                    let previous = history.calls[index].input
                    history.calls[index].input = input
                    return previous
                }
            }
            return (ready, session.observationWake(), retired)
        }
        delivery?.publish()
        wake?.publish()
        // A projected payload's destructor may reenter the session.
        withExtendedLifetime(retired) {}
    }

    private static func retainedIndex(of admission: JournalAdmission, in calls: [Invocation<Input>]) -> Int {
        guard let first = calls.first else {
            preconditionFailure("Current-epoch admission is missing from its endpoint")
        }
        return Int(admission.id - first.id)
    }

    func snapshot(validating expectedEpoch: SessionEpoch? = nil) -> JournalSnapshot<Input> {
        scope.session.withLock { session in
            let stale = expectedEpoch.map { $0 != session.epoch } ?? false
            return snapshot(epoch: session.epoch, stale: stale)
        }
    }

    private func snapshot(epoch: SessionEpoch, stale: Bool = false) -> JournalSnapshot<Input> {
        state.withLock {
            JournalSnapshot(calls: stale ? [] : $0.calls, watermark: $0.nextID,
                            epoch: epoch, isStale: stale)
        }
    }

    func captureForConsumption(in consumptionScope: SessionConsumptionScope) throws(SessionConsumptionError)
        -> (journal: JournalSnapshot<Input>, claims: SessionConsumptionClaims, watermark: UInt64) {
        try scope.session.withLock { session throws(SessionConsumptionError) in
            let (prefix, claims) = try session.captureConsumption(in: consumptionScope)
            guard prefix.prunedThrough == nil else { throw .historyUnavailable }
            return (snapshot(epoch: prefix.epoch), claims, prefix.watermark)
        }
    }

    func commitPreparedConsumption(_ prepared: PreparedSessionConsumption) throws(SessionConsumptionError) {
        _ = try scope.session.commitConsumption(prepared)
    }

    // Called by the session under its lock, in the same order as admission.
    // The session keeps the returned copy alive until both locks have been released.
    func discardHistory() -> any Sendable {
        state.withLock {
            let retired = $0.calls
            $0.calls = []
            return retired
        }
    }

    func verification(matching matcher: Matcher<Input>, phase: CallPhase) -> Verification<Input> {
        let epoch = scope.session.withLock { $0.epoch }
        return Verification(journal: self, matcher: matcher, phase: phase, epoch: epoch)
    }

    func report(_ issue: MockIssue) {
        state.withLock { $0.issues.append(issue) }
        reporter.report(issue) // Consumer code must run after releasing synchronization.
    }

    func reportMissingCall(_ admission: JournalAdmission, phase: CallPhase? = nil, source: SourceLocation) -> MockIssue {
        reportUnansweredCall(admission, phase: phase, source: source, reason: .noMatchingStub)
    }

    fileprivate func reportUnansweredCall(
        _ admission: JournalAdmission, phase: CallPhase? = nil,
        source: SourceLocation, reason: UnansweredCallReason
    ) -> MockIssue {
        if let phase { complete(admission, phase: phase) }
        let kind: MockIssue.Kind
        let message: String
        switch reason {
        case .noMatchingStub:
            kind = .unexpectedCall
            message = "No matching stub for \(endpoint.rawValue)"
        case .exhaustedSequence:
            kind = .sequenceExhausted
            message = "Stub answer sequence exhausted for \(endpoint.rawValue)"
        }
        let issue = MockIssue(kind: kind, endpoint: endpoint, message: message,
                              source: source, watermark: admission.id)
        report(issue)
        return issue
    }

    func reportFinishedCall(source: SourceLocation) -> MockIssue {
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint,
                              message: "Cannot call \(endpoint.rawValue) in a finished mock session",
                              source: source, watermark: state.withLock { $0.nextID })
        report(issue)
        return issue
    }

    func resolveFinishedNonthrowingCall<Output: Sendable>(
        source: SourceLocation, fallback: (@Sendable (MockIssue) -> Output)?
    ) -> Output {
        let issue = reportFinishedCall(source: source)
        guard let fallback else { fatalError(issue.message) }
        return fallback(issue)
    }

    func resolveMissingNonthrowingCall<Output: Sendable>(
        _ admission: JournalAdmission,
        source: SourceLocation,
        fallback: (@Sendable (MockIssue) -> Output)?
    ) -> Output {
        guard let fallback else {
            let issue = reportMissingCall(admission, phase: .terminated, source: source)
            fatalError(issue.message)
        }
        let issue = reportMissingCall(admission, source: source)
        let result = fallback(issue)
        complete(admission, phase: .returned)
        return result
    }
}

extension ConfiguredJournal where Configuration == Void {
    convenience init(endpoint: EndpointID, reporter: FailureReporter, scope: MockScope) {
        self.init(endpoint: endpoint, reporter: reporter, scope: scope, configuration: ())
    }

    func begin(_ input: Input) -> JournalAdmission? { admit(input)?.admission }
}

public struct Verification<Input: Sendable>: Sendable {
    fileprivate let journal: any VerificationJournal<Input>
    fileprivate let matcher: Matcher<Input>
    fileprivate let phase: CallPhase
    fileprivate let epoch: SessionEpoch

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
        let prefix = journal.snapshot(validating: epoch)
        if prefix.isStale {
            journal.report(MockIssue(
                kind: .verificationFailed, endpoint: journal.endpoint,
                message: "Verification belongs to an earlier session epoch. Create a new descriptor after resetting history.",
                source: source(), watermark: prefix.watermark))
            return VerificationResult(passed: false, observed: 0, watermark: prefix.watermark,
                                      invocationIDs: [], epoch: epoch, isStale: true)
        }
        let matches = prefix.calls.filter {
            (phase == .admitted || $0.phase == phase) && matcher.matches($0.input)
        }
        let failure = count.failureMessage(observed: matches.count)
        if let failure {
            journal.report(MockIssue(
                kind: .verificationFailed, endpoint: journal.endpoint,
                message: failure,
                source: source(),
                watermark: prefix.watermark))
        }
        return VerificationResult(passed: failure == nil, observed: matches.count,
                                  watermark: prefix.watermark, invocationIDs: matches.map(\.id), epoch: prefix.epoch)
    }
}

struct Rule<Input: Sendable, Answer: Sendable>: Sendable {
    let matcher: Matcher<Input>
    let answer: Answer
}

public struct SyncConfiguration<Input: Sendable, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<Input, @Sendable (Input) -> Output>]

    func answer(matching input: Input) -> (@Sendable (Input) -> Output)? {
        rules.reversed().first { $0.matcher.matches(input) }?.answer
    }
}
/// Setup is confined to its caller. finish() publishes an immutable plan.
public final class SyncStubbing<Input: Sendable, Output: Sendable> {
    private var rules: [Rule<Input, @Sendable (Input) -> Output>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> SyncStub<Input, Output> {
        SyncStub(owner: self, matcher: matcher)
    }
    fileprivate func add(_ matcher: Matcher<Input>, _ answer: @escaping @Sendable (Input) -> Output) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: answer))
    }
    public func finish() -> SyncConfiguration<Input, Output> {
        precondition(!finished, "Setup is already published")
        finished = true
        return SyncConfiguration(rules: rules)
    }
}
public struct SyncStub<Input: Sendable, Output: Sendable> {
    fileprivate let owner: SyncStubbing<Input, Output>
    fileprivate let matcher: Matcher<Input>
    public func willReturn(_ output: Output) { owner.add(matcher) { _ in output } }
    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) { owner.add(matcher, answer) }
}

public final class SyncEndpoint<Input: Sendable, Output: Sendable>: Sendable {
    private let configuration: SyncConfiguration<Input, Output>
    private let journal: Journal<Input>
    private let fallback: (@Sendable (MockIssue) -> Output)?

    /// Reports an unstubbed call before invoking the fallback. Without one, it terminates after reporting.
    public init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                fallback: (@Sendable (MockIssue) -> Output)? = nil) {
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.fallback = fallback
    }
    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        // Last registration wins. Matching and answer execution are outside the journal lock.
        if let answer = configuration.answer(matching: input) {
            let result = answer(input)
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

// Storing a typed-throwing function in a generic rule needs a newer OS runtime.
// The stored Result preserves the public typed error on the original deployment floors.
private typealias AsyncAnswer<Input, Output, Failure: Error> =
    @Sendable (Input) async -> Result<Output, Failure>

/// A legal step for a Sendable async endpoint's exact input, result, and thrown error.
public struct AsyncThrowingSequenceStep<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let answer: AsyncAnswer<Input, Output, Failure>

    public static func returning(_ output: Output) -> Self {
        Self(answer: { _ in .success(output) })
    }

    public static func throwing(_ failure: Failure) -> Self {
        Self(answer: { _ in .failure(failure) })
    }

    public static func answering(_ body: @escaping @Sendable (Input) async throws(Failure) -> Output) -> Self {
        Self(answer: { input in
            do throws(Failure) { return .success(try await body(input)) }
            catch { return .failure(error) }
        })
    }
}

public struct AsyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [Rule<Input, PlannedAnswer<AsyncAnswer<Input, Output, Failure>>>]

    fileprivate func publish() -> PublishedAsyncThrowingConfiguration<Input, Output, Failure> {
        PublishedAsyncThrowingConfiguration(
            rules: rules.map { Rule(matcher: $0.matcher, answer: $0.answer.publish()) }
        )
    }
}

private struct PublishedAsyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let rules: [Rule<Input, PublishedAnswer<AsyncAnswer<Input, Output, Failure>>>]
}

public final class AsyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    private var rules: [Rule<Input, PlannedAnswer<AsyncAnswer<Input, Output, Failure>>>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> AsyncThrowingStub<Input, Output, Failure> {
        AsyncThrowingStub(owner: self, matcher: matcher)
    }
    fileprivate func add(_ matcher: Matcher<Input>, _ answer: PlannedAnswer<AsyncAnswer<Input, Output, Failure>>) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: answer))
    }
    public func finish() -> AsyncThrowingConfiguration<Input, Output, Failure> {
        precondition(!finished, "Setup is already published")
        finished = true
        return AsyncThrowingConfiguration(rules: rules)
    }
}
public struct AsyncThrowingStub<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let owner: AsyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: Matcher<Input>
    public func willReturn(_ output: Output) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.returning(output).answer))
    }
    public func willThrow(_ error: Failure) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.throwing(error).answer))
    }
    public func willAnswer(_ answer: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.answering(answer).answer))
    }

    /// Reserves one step for each matching call. An exhausted finite sequence
    /// reports a failure instead of falling through to an earlier rule.
    public func willSequence(
        _ first: AsyncThrowingSequenceStep<Input, Output, Failure>,
        _ remaining: AsyncThrowingSequenceStep<Input, Output, Failure>...,
        policy: StubSequencePolicy = .finite
    ) {
        owner.add(matcher, .sequence([first.answer] + remaining.map(\.answer), policy))
    }
}

public final class AsyncThrowingEndpoint<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let journal: ConfiguredJournal<Input, PublishedAsyncThrowingConfiguration<Input, Output, Failure>>
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?
    public init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                failureMapping: (@Sendable (MockIssue) -> Failure)? = nil) {
        self.failureMapping = failureMapping
        self.journal = ConfiguredJournal(endpoint: id, reporter: failureReporter, scope: scope,
                                         configuration: configuration.publish())
    }

    /// Atomically replaces the plan for subsequent admissions. Existing invocations keep their admitted plan.
    @discardableResult
    public func replaceConfiguration(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>) -> RuleRevision {
        journal.replaceConfiguration(configuration.publish())
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async throws(Failure) -> Output {
        guard let (admission, configuration) = journal.admit(input) else {
            let issue = journal.reportFinishedCall(source: source)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        }
        defer { withExtendedLifetime(configuration) {} }
        let winningRule = configuration.rules.reversed().first { $0.matcher.matches(input) }
        if let answer = winningRule?.answer.reserve() {
            switch await answer(input) {
            case .success(let result):
                journal.complete(admission, phase: .returned)
                return result
            case .failure(let error):
                journal.complete(admission, phase: .threw)
                throw error
            }
        }
        let reason: UnansweredCallReason = winningRule == nil ? .noMatchingStub : .exhaustedSequence
        if let failureMapping {
            let issue = journal.reportUnansweredCall(admission, source: source, reason: reason)
            let error = failureMapping(issue)
            journal.complete(admission, phase: .threw)
            throw error
        }
        let issue = journal.reportUnansweredCall(admission, phase: .terminated, source: source, reason: reason)
        fatalError(issue.message)
    }
    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        journal.verification(matching: matcher, phase: phase)
    }
    public var invocations: [Invocation<Input>] { journal.snapshot().calls }
}
