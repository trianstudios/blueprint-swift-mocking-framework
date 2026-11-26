import Foundation

// A compile-time generated-code/runtime schema marker. This is not a release version.
public enum BlueprintRuntimeSchemaV1 {
    /// Reports a generated type-level call that had no bound mock scope.
    @discardableResult
    public static func reportMissingTypeScope(_ id: EndpointID, source: SourceLocation) -> String {
        let message = "Missing type-level mock scope for \(id.diagnosticName)"
        let diagnostic = "\(source.filePath):\(source.line):\(source.column): error: BlueprintMocking: \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(diagnostic.utf8))
        return message
    }
}

/// The process-local identity and readable diagnostic name of a concrete type argument.
public struct EndpointSpecialization: Sendable, Equatable {
    public let typeName: String
    private let typeIdentity: ObjectIdentifier

    fileprivate init<Argument>(_ type: Argument.Type) {
        self.typeName = String(reflecting: type)
        self.typeIdentity = ObjectIdentifier(type)
    }
}

public struct EndpointID: Sendable, Equatable {
    /// The declaration identity shared by all of its specializations.
    public let rawValue: String
    public let specialization: EndpointSpecialization?

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.specialization = nil
    }

    public init<Argument>(_ rawValue: String, specializedFor type: Argument.Type) {
        self.rawValue = rawValue
        self.specialization = EndpointSpecialization(type)
    }

    var diagnosticName: String {
        guard let specialization else { return rawValue }
        return "\(rawValue) [\(specialization.typeName)]"
    }
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

/// A terminal outcome produced by invoking a real provider or a linked endpoint.
public enum CallOrigin: Sendable, Equatable { case forwarded }

public struct Invocation<Input: Sendable>: Sendable {
    public let id: UInt64
    public fileprivate(set) var input: Input
    public let configurationRevision: RuleRevision
    public let sessionInvocationID: SessionInvocationID
    public let epoch: SessionEpoch
    public fileprivate(set) var phase: CallPhase
    /// The forwarding origin once a forwarded invocation settles.
    public fileprivate(set) var origin: CallOrigin?
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

struct ProjectionTimelineFields: OptionSet, Sendable {
    let rawValue: UInt8
    static let argument = Self(rawValue: 1)
    static let result = Self(rawValue: 2)

    static func strings(argument: Any.Type, result: Any.Type) -> Self {
        var fields: Self = []
        if argument == String.self { fields.insert(.argument) }
        if result == String.self { fields.insert(.result) }
        return fields
    }
}

enum ProjectionJournalChange<Input: Sendable>: Sendable {
    case admitted
    case argument(Input)
    case completed(CallPhase, Input?)
}

struct ProjectionJournalEvent<Input: Sendable>: Sendable {
    let ordinal: UInt64
    let elapsed: Duration
    let invocationID: SessionInvocationID
    let change: ProjectionJournalChange<Input>
}

struct ProjectionJournalCut<Input: Sendable>: Sendable {
    let snapshot: SessionSnapshot
    let elapsed: Duration
    let events: [ProjectionJournalEvent<Input>]
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

fileprivate enum UnansweredCallReason: Sendable {
    case noMatchingStub
    case exhaustedSequence
    case forwardingDepthExceeded(Int)
    case forwardingCycle([String])
    case forwardingTargetUnbound
    case forwardingTargetReleased
}

typealias Journal<Input: Sendable> = ConfiguredJournal<Input, Void>

final class ConfiguredJournal<Input: Sendable, Configuration: Sendable>: VerificationJournal, SessionJournalRegistration {
    private struct State: Sendable {
        var configuration: Configuration
        var revision = RuleRevision(rawValue: 0)
        var nextID: UInt64 = 0
        var calls: [Invocation<Input>] = []
        var projectionEvents: [ProjectionJournalEvent<Input>] = []
        var issues: [MockIssue] = []
    }

    private let state: CriticalState<State>
    private let scope: MockScope
    private let tracksProjectionTimeline: ProjectionTimelineFields
    let endpoint: EndpointID
    private let reporter: FailureReporter

    init(endpoint: EndpointID, reporter: FailureReporter, scope: MockScope,
         configuration: Configuration, tracksProjectionTimeline: ProjectionTimelineFields = []) {
        self.state = CriticalState(State(configuration: configuration))
        self.tracksProjectionTimeline = tracksProjectionTimeline
        self.scope = scope
        self.endpoint = endpoint
        self.reporter = reporter
        scope.session.register(self)
    }

    func admit(_ input: Input) -> (admission: JournalAdmission, configuration: Configuration)? {
        // Lock order is session, then this endpoint. No operation holds two endpoint locks.
        let (result, wake) = scope.session.withLock {
            session -> ((admission: JournalAdmission, configuration: Configuration)?, SessionObservationDelivery?) in
            guard scope.admissionRejection(in: session) == nil else { return (nil, nil) }
            let result = state.withLock {
                $0.nextID += 1
                let id = $0.nextID
                let event = session.admit(mockID: scope.id, endpoint: endpoint,
                                          configurationRevision: $0.revision)
                $0.calls.append(Invocation(id: id, input: input, configurationRevision: $0.revision,
                                          sessionInvocationID: event.invocationID, epoch: event.epoch,
                                          phase: .admitted, origin: nil))
                if !tracksProjectionTimeline.isEmpty {
                    $0.projectionEvents.append(ProjectionJournalEvent(
                        ordinal: event.ordinal, elapsed: event.elapsed, invocationID: event.invocationID, change: .admitted
                    ))
                }
                return (JournalAdmission(id: id, event: event), $0.configuration)
            }
            return (result, session.observationWake())
        }
        wake?.publish()
        return result
    }

    func replaceConfiguration(_ configuration: Configuration) -> RuleRevision {
        let (revision, retired) = swapConfiguration(configuration)
        // A captured object can run user code in deinit.
        withExtendedLifetime(retired) {}
        return revision
    }

    func replaceConfigurationIfQuiescent(_ configuration: Configuration)
        throws(QuiescentConfigurationError) -> RuleRevision {
        let (revision, retired) = try scope.session.withLock {
            session throws(QuiescentConfigurationError) -> (RuleRevision, Configuration) in
            switch scope.admissionRejection(in: session) {
            case .finished: throw .finishedSession
            case .staleTypeScope: throw .staleScope
            case nil: break
            }
            let count = session.activeInvocationCountAcrossEpochs
            guard count == 0 else { throw .activeInvocations(count: count) }
            return swapConfiguration(configuration)
        }
        // The retired plan can reenter both the session and the endpoint.
        withExtendedLifetime(retired) {}
        return revision
    }

    private func swapConfiguration(_ configuration: Configuration) -> (RuleRevision, Configuration) {
        state.withLock {
            let retired = $0.configuration
            let revision = RuleRevision(rawValue: $0.revision.rawValue + 1)
            $0.configuration = configuration
            $0.revision = revision
            return (revision, retired)
        }
    }

    func update(_ admission: JournalAdmission, replacing input: Input) {
        let (retired, wake) = scope.session.withLock { session -> (Input?, SessionObservationDelivery?) in
            guard admission.event.epoch == session.epoch else { return (nil, nil) }
            let retired = state.withLock { history in
                let index = Self.retainedIndex(of: admission, in: history.calls)
                precondition(history.calls[index].phase == .admitted, "Cannot update a completed invocation")
                let previous = history.calls[index].input
                history.calls[index].input = input
                if tracksProjectionTimeline.contains(.argument) {
                    let position = session.recordProjectionPosition()
                    history.projectionEvents.append(ProjectionJournalEvent(
                        ordinal: position.ordinal, elapsed: position.elapsed,
                        invocationID: admission.event.invocationID, change: .argument(input)
                    ))
                }
                return previous
            }
            return (retired, session.observationWake())
        }
        wake?.publish()
        withExtendedLifetime(retired) {}
    }

    func complete(
        _ admission: JournalAdmission, phase: CallPhase, origin: CallOrigin? = nil, replacing input: Input? = nil
    ) {
        let (delivery, wake, retired) = scope.session.withLock { session in
            let (terminal, ready) = session.complete(admission.event.invocationID, phase: phase, origin: origin)
            var retired: Input? = nil
            if admission.event.epoch == session.epoch {
                retired = state.withLock { history -> Input? in
                    let index = Self.retainedIndex(of: admission, in: history.calls)
                    history.calls[index].phase = phase
                    history.calls[index].origin = origin
                    if tracksProjectionTimeline.contains(.result) {
                        history.projectionEvents.append(ProjectionJournalEvent(
                            ordinal: terminal.ordinal, elapsed: terminal.elapsed,
                            invocationID: terminal.invocationID, change: .completed(phase, input)
                        ))
                    }
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

    var projectionSession: MockSession { scope.session }

    func timedProjectionCut() -> ProjectionJournalCut<Input> {
        scope.session.withLock { session in
            let (snapshot, elapsed) = session.timedSnapshot()
            let events = state.withLock { $0.projectionEvents }
            return ProjectionJournalCut(snapshot: snapshot, elapsed: elapsed, events: events)
        }
    }

    // Called by the session under its lock, in the same order as admission.
    // The session keeps the returned copy alive until both locks have been released.
    func discardHistory() -> any Sendable {
        state.withLock {
            let retired = ($0.calls, $0.projectionEvents)
            $0.calls = []
            $0.projectionEvents = []
            return retired
        }
    }

    func verification(matching matcher: Matcher<Input>, phase: CallPhase, origin: CallOrigin? = nil)
        -> Verification<Input> {
        let epoch = scope.expectedEpoch ?? scope.session.withLock { $0.epoch }
        return Verification(journal: self, matcher: matcher, phase: phase, epoch: epoch,
                            isEpochBound: scope.expectedEpoch != nil, origin: origin)
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
            message = "No matching stub for \(endpoint.diagnosticName)"
        case .exhaustedSequence:
            kind = .sequenceExhausted
            message = "Stub answer sequence exhausted for \(endpoint.diagnosticName)"
        case .forwardingDepthExceeded(let limit):
            kind = .unexpectedCall
            message = "Forwarding depth limit \(limit) exceeded for \(endpoint.diagnosticName)"
        case .forwardingCycle(let route):
            kind = .unexpectedCall
            message = "Forwarding cycle detected for \(endpoint.diagnosticName): \(route.joined(separator: " -> "))"
        case .forwardingTargetUnbound:
            kind = .unexpectedCall
            message = "Forwarding target is unbound for \(endpoint.diagnosticName)"
        case .forwardingTargetReleased:
            kind = .unexpectedCall
            message = "Forwarding target was released for \(endpoint.diagnosticName)"
        }
        let issue = MockIssue(kind: kind, endpoint: endpoint, message: message,
                              source: source, watermark: admission.id)
        report(issue)
        return issue
    }

    func reportFinishedCall(source: SourceLocation, terminating: Bool) -> MockIssue {
        let (rejection, closedEpoch) = scope.session.withLock {
            (scope.admissionRejection(in: $0) ?? .finished, $0.isFinished ? $0.epoch : nil)
        }
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint,
                              message: rejection.message(for: endpoint),
                              source: source, watermark: state.withLock { $0.nextID })
        if !scope.bufferOrphan(issue, closedEpoch: closedEpoch, terminating: terminating) {
            report(issue)
        }
        return issue
    }

    func resolveFinishedNonthrowingCall<Output: Sendable>(
        source: SourceLocation, fallback: (@Sendable (MockIssue) -> Output)?
    ) -> Output {
        let issue = reportFinishedCall(source: source, terminating: fallback == nil)
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
    convenience init(endpoint: EndpointID, reporter: FailureReporter, scope: MockScope,
                     tracksProjectionTimeline: ProjectionTimelineFields = []) {
        self.init(endpoint: endpoint, reporter: reporter, scope: scope, configuration: (),
                  tracksProjectionTimeline: tracksProjectionTimeline)
    }

    func begin(_ input: Input) -> JournalAdmission? { admit(input)?.admission }
}

public struct Verification<Input: Sendable>: Sendable {
    fileprivate let journal: any VerificationJournal<Input>
    fileprivate let matcher: Matcher<Input>
    fileprivate let phase: CallPhase
    fileprivate let epoch: SessionEpoch
    fileprivate let isEpochBound: Bool
    fileprivate let origin: CallOrigin?

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
            let message = isEpochBound
                ? "Verification belongs to an earlier type-level mock scope. Create a new scope after resetting history."
                : "Verification belongs to an earlier session epoch. Create a new descriptor after resetting history."
            journal.report(MockIssue(kind: .verificationFailed, endpoint: journal.endpoint,
                                     message: message, source: source(), watermark: prefix.watermark))
            return VerificationResult(passed: false, observed: 0, watermark: prefix.watermark,
                                      invocationIDs: [], epoch: epoch, isStale: true)
        }
        let matches = prefix.calls.filter {
            (phase == .admitted || $0.phase == phase) &&
                (origin == nil || $0.origin == origin) && matcher.matches($0.input)
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

fileprivate struct SyncRuleBehavior<Input: Sendable, Output: Sendable>: Sendable {
    let answer: @Sendable (Input) -> Output
    let capture: WinningRuleCapture<Input>?
}

public struct SyncConfiguration<Input: Sendable, Output: Sendable>: Sendable {
    fileprivate let rules: [Rule<Input, SyncRuleBehavior<Input, Output>>]

    func validateCaptureSession(_ sessionID: SessionID) {
        precondition(rules.allSatisfy { $0.answer.capture.map { $0.sessionID == sessionID } ?? true },
                     "Argument captor belongs to a different mock session")
    }

    func answer(matching input: Input, recording admission: SessionEvent) -> (@Sendable (Input) -> Output)? {
        guard let winner = rules.reversed().first(where: { $0.matcher.matches(input) }) else { return nil }
        winner.answer.capture?.publish(input, admission)
        return winner.answer.answer
    }
}
/// Setup is confined to its caller. finish() publishes an immutable plan.
public final class SyncStubbing<Input: Sendable, Output: Sendable> {
    private var rules: [Rule<Input, SyncRuleBehavior<Input, Output>>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> SyncStub<Input, Output> {
        SyncStub(owner: self, matcher: matcher, capture: nil)
    }
    fileprivate func add(_ matcher: Matcher<Input>, _ behavior: SyncRuleBehavior<Input, Output>) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: behavior))
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
    fileprivate let capture: WinningRuleCapture<Input>?

    /// Projects the argument once when this rule wins, before its answer executes.
    /// A second call replaces the policy on the returned descriptor. The captor and
    /// endpoint must use the same session, or endpoint initialization fails a precondition.
    public func capturing<Value: Sendable>(
        into captor: ArgumentCaptor<Value>, projecting projection: @escaping @Sendable (Input) -> Value
    ) -> Self {
        SyncStub(owner: owner, matcher: matcher, capture: WinningRuleCapture(captor: captor, projecting: projection))
    }

    public func willReturn(_ output: Output) { willAnswer { _ in output } }

    public func willAnswer(_ answer: @escaping @Sendable (Input) -> Output) {
        owner.add(matcher, SyncRuleBehavior(answer: answer, capture: capture))
    }
}

public final class SyncEndpoint<Input: Sendable, Output: Sendable>: Sendable {
    private let configuration: SyncConfiguration<Input, Output>
    private let journal: Journal<Input>
    private let forwarding: (@Sendable (Input) -> Output)?
    private let fallback: (@Sendable (MockIssue) -> Output)?

    /// Reports an unstubbed call before invoking the failure fallback.
    public convenience init(
        id: EndpointID, configuration: SyncConfiguration<Input, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: nil, fallback: fallback)
    }

    /// Calls the real implementation on a stub miss if supplied.
    public init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                forwarding: (@Sendable (Input) -> Output)?,
                fallback: (@Sendable (MockIssue) -> Output)? = nil) {
        configuration.validateCaptureSession(scope.session.id)
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.forwarding = forwarding
        self.fallback = fallback
    }
    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(input) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        // Last registration wins. Matching and answer execution are outside the journal lock.
        let stub = configuration.answer(matching: input, recording: admission.event)
        if let answer = stub ?? forwarding {
            let result = answer(input)
            journal.complete(admission, phase: .returned, origin: stub == nil ? .forwarded : nil)
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

// Storing a typed-throwing function in a generic rule needs a newer OS runtime.
// The stored Result preserves the public typed error on the original deployment floors.
private typealias AsyncAnswer<Input, Output, Failure: Error> =
    @Sendable (Input) async -> Result<Output, Failure>

fileprivate enum AsyncDispatchOutcome<Output: Sendable, Failure: Error>: Sendable {
    case answered(Result<Output, Failure>, origin: CallOrigin?)
    case unanswered(UnansweredCallReason)
}

// Retained for the duration of traversal; no endpoint is kept alive by the path.
final class AsyncForwardingInstance: Sendable {
    let id: EndpointID

    init(id: EndpointID) { self.id = id }
}

/// A forwarding route for a checked Sendable async throwing endpoint.
public struct AsyncThrowingForwarding<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private enum Route: Sendable {
        case implementation(AsyncAnswer<Input, Output, Failure>, maximumDepth: Int?)
        case link(AsyncThrowingForwardingLink<Input, Output, Failure>)
    }

    private let route: Route

    public init(_ body: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        self.init(maximumDepth: nil, body)
    }

    /// Limits active forwarding hops on this task's connected path. The depth must be positive if supplied.
    public init(maximumDepth: Int?, _ body: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        precondition(maximumDepth.map { $0 > 0 } ?? true, "Maximum forwarding depth must be positive")
        route = .implementation({ input in
            do throws(Failure) { return .success(try await body(input)) }
            catch { return .failure(error) }
        }, maximumDepth: maximumDepth)
    }

    /// Forwards through a framework-owned endpoint link on a stub miss.
    public init(link: AsyncThrowingForwardingLink<Input, Output, Failure>) {
        route = .link(link)
    }

    fileprivate func forward(
        _ input: Input, source: SourceLocation, instance: AsyncForwardingInstance,
        path: [AsyncForwardingInstance]
    ) async -> AsyncDispatchOutcome<Output, Failure> {
        let maximumDepth: Int?
        let perform: @Sendable () async -> Result<Output, Failure>
        switch route {
        case .implementation(let answer, let limit):
            maximumDepth = limit
            perform = { await answer(input) }
        case .link(let link):
            let nextPath = path + [instance]
            if path.contains(where: { $0 === instance }) {
                return .unanswered(.forwardingCycle(nextPath.map { $0.id.diagnosticName }))
            }
            switch link.snapshot() {
            case .unbound:
                return .unanswered(.forwardingTargetUnbound)
            case .released:
                return .unanswered(.forwardingTargetReleased)
            case .available(let target):
                maximumDepth = nil
                perform = {
                    do throws(Failure) {
                        return .success(try await target.invoke(input, source: source, forwardingPath: nextPath))
                    } catch {
                        return .failure(error)
                    }
                }
            }
        }
        switch await AsyncForwardingDepth.run(maximumDepth: maximumDepth, perform) {
        case .completed(let result):
            return .answered(result, origin: .forwarded)
        case .exceeded(let limit):
            return .unanswered(.forwardingDepthExceeded(limit))
        }
    }
}

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

fileprivate struct AsyncRuleBehavior<Input: Sendable, Plan: Sendable>: Sendable {
    let plan: Plan
    let capture: WinningRuleCapture<Input>?
}

fileprivate typealias PlannedAsyncThrowingRule<Input: Sendable, Output: Sendable, Failure: Error> =
    Rule<Input, AsyncRuleBehavior<Input, PlannedAnswer<AsyncAnswer<Input, Output, Failure>>>>

public struct AsyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let rules: [PlannedAsyncThrowingRule<Input, Output, Failure>]

    fileprivate func publish(for sessionID: SessionID) -> PublishedAsyncThrowingConfiguration<Input, Output, Failure> {
        precondition(rules.allSatisfy { $0.answer.capture.map { $0.sessionID == sessionID } ?? true },
                     "Argument captor belongs to a different mock session")
        return PublishedAsyncThrowingConfiguration(rules: rules.map { rule in
            Rule(matcher: rule.matcher, answer: AsyncRuleBehavior(
                plan: rule.answer.plan.publish(), capture: rule.answer.capture))
        })
    }
}

private struct PublishedAsyncThrowingConfiguration<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    let rules: [Rule<Input, AsyncRuleBehavior<Input, PublishedAnswer<AsyncAnswer<Input, Output, Failure>>>>]
}

public final class AsyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    private var rules: [PlannedAsyncThrowingRule<Input, Output, Failure>] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> AsyncThrowingStub<Input, Output, Failure> {
        AsyncThrowingStub(owner: self, matcher: matcher, capture: nil)
    }
    fileprivate func add(
        _ matcher: Matcher<Input>, _ answer: PlannedAnswer<AsyncAnswer<Input, Output, Failure>>,
        capture: WinningRuleCapture<Input>?
    ) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        rules.append(Rule(matcher: matcher, answer: AsyncRuleBehavior(plan: answer, capture: capture)))
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
    fileprivate let capture: WinningRuleCapture<Input>?

    /// Projects the argument once after this rule reserves an answer and before it executes.
    /// A second call replaces the policy on the returned descriptor. The captor and
    /// endpoint must use the same session at initialization and configuration replacement.
    public func capturing<Value: Sendable>(
        into captor: ArgumentCaptor<Value>, projecting projection: @escaping @Sendable (Input) -> Value
    ) -> Self {
        AsyncThrowingStub(owner: owner, matcher: matcher,
                          capture: WinningRuleCapture(captor: captor, projecting: projection))
    }

    public func willReturn(_ output: Output) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.returning(output).answer),
                  capture: capture)
    }
    public func willThrow(_ error: Failure) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.throwing(error).answer),
                  capture: capture)
    }
    public func willAnswer(_ answer: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        owner.add(matcher, .single(AsyncThrowingSequenceStep<Input, Output, Failure>.answering(answer).answer),
                  capture: capture)
    }

    /// Reserves one step for each matching call. An exhausted finite sequence
    /// reports a failure instead of falling through to an earlier rule.
    public func willSequence(
        _ first: AsyncThrowingSequenceStep<Input, Output, Failure>,
        _ remaining: AsyncThrowingSequenceStep<Input, Output, Failure>...,
        policy: StubSequencePolicy = .finite
    ) {
        owner.add(matcher, .sequence([first.answer] + remaining.map(\.answer), policy), capture: capture)
    }
}

/// Shared typed dispatch for raw and projection-only histories.
struct AsyncThrowingDispatch<Input: Sendable, Output: Sendable, Failure: Error, History: Sendable>: Sendable {
    private let journal: ConfiguredJournal<History, PublishedAsyncThrowingConfiguration<Input, Output, Failure>>
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?
    private let forwarding: AsyncThrowingForwarding<Input, Output, Failure>?
    private let forwardingInstance: AsyncForwardingInstance
    private let sessionID: SessionID

    init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
         failureReporter: FailureReporter, scope: MockScope,
         forwarding: AsyncThrowingForwarding<Input, Output, Failure>? = nil,
         failureMapping: (@Sendable (MockIssue) -> Failure)?, tracksProjectionTimeline: ProjectionTimelineFields = []) {
        self.sessionID = scope.session.id
        self.forwarding = forwarding
        self.forwardingInstance = AsyncForwardingInstance(id: id)
        self.failureMapping = failureMapping
        journal = ConfiguredJournal(endpoint: id, reporter: failureReporter, scope: scope,
                                    configuration: configuration.publish(for: sessionID),
                                    tracksProjectionTimeline: tracksProjectionTimeline)
    }

    func replaceConfiguration(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>) -> RuleRevision {
        journal.replaceConfiguration(configuration.publish(for: sessionID))
    }

    func replaceConfigurationIfQuiescent(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>)
        throws(QuiescentConfigurationError) -> RuleRevision {
        try journal.replaceConfigurationIfQuiescent(configuration.publish(for: sessionID))
    }

    func snapshot() -> JournalSnapshot<History> { journal.snapshot() }

    func prepareArgumentStability<Result: Sendable>(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<History> where History == ProjectedFields<String, Result> {
        try journal.prepareArgumentStability(count, matchingArgument: argument, for: duration, within: timeout)
    }

    func prepareResultStability<Argument: Sendable>(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<History> where History == ProjectedFields<Argument, String> {
        try journal.prepareResultStability(count, matchingResult: result, for: duration, within: timeout)
    }

    func consumeProjected<Argument: Sendable, Result: Sendable>(
        _ selection: SessionConsumptionSelection, matchingArgument matcher: Matcher<Argument>,
        phase: CallPhase, in scope: SessionConsumptionScope
    ) throws(ProjectedConsumptionError) -> ProjectedSessionConsumption<Argument, Result>
        where History == ProjectedFields<Argument, Result> {
        try journal.consumeProjected(selection, matchingArgument: matcher, phase: phase, in: scope)
    }

    func verification(matching matcher: Matcher<History>, phase: CallPhase, origin: CallOrigin? = nil)
        -> Verification<History> {
        journal.verification(matching: matcher, phase: phase, origin: origin)
    }

    func invoke(
        _ input: Input, recording initialHistory: History, source: SourceLocation,
        forwardingPath: [AsyncForwardingInstance] = [],
        argumentProjection: @Sendable (Input) -> History? = { _ in nil },
        completionProjection: @Sendable (History, Output?) -> History? = { _, _ in nil }
    ) async throws(Failure) -> Output {
        guard let (admission, configuration) = journal.admit(initialHistory) else {
            let issue = journal.reportFinishedCall(source: source, terminating: failureMapping == nil)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        }
        defer { withExtendedLifetime(configuration) {} }

        // User projections, rule matching, answer execution, and error mapping all run
        // after admission, outside journal and sequence locks.
        let projected = argumentProjection(input)
        if let projected { journal.update(admission, replacing: projected) }
        let history = projected ?? initialHistory

        let winningRule = configuration.rules.reversed().first { $0.matcher.matches(input) }
        let outcome: AsyncDispatchOutcome<Output, Failure>
        if let winningRule {
            if let answer = winningRule.answer.plan.reserve() {
                winningRule.answer.capture?.publish(input, admission.event)
                outcome = .answered(await answer(input), origin: nil)
            } else {
                outcome = .unanswered(.exhaustedSequence)
            }
        } else if let forwarding {
            outcome = await forwarding.forward(input, source: source, instance: forwardingInstance,
                                               path: forwardingPath)
        } else {
            outcome = .unanswered(.noMatchingStub)
        }

        switch outcome {
        case .answered(.success(let output), let origin):
            // An optional Output may legitimately be nil. The outer .some still identifies a return.
            journal.complete(
                admission, phase: .returned, origin: origin, replacing: completionProjection(history, .some(output))
            )
            return output
        case .answered(.failure(let error), let origin):
            journal.complete(admission, phase: .threw, origin: origin, replacing: completionProjection(history, nil))
            throw error
        case .unanswered(let reason):
            if let failureMapping {
                let issue = journal.reportUnansweredCall(admission, source: source, reason: reason)
                let error = failureMapping(issue)
                journal.complete(admission, phase: .threw, replacing: completionProjection(history, nil))
                throw error
            }
            journal.complete(admission, phase: .terminated, replacing: completionProjection(history, nil))
            let issue = journal.reportUnansweredCall(admission, source: source, reason: reason)
            fatalError(issue.message)
        }
    }
}

public final class AsyncThrowingEndpoint<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private let dispatch: AsyncThrowingDispatch<Input, Output, Failure, Input>

    public convenience init(
        id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        failureMapping: (@Sendable (MockIssue) -> Failure)? = nil
    ) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: nil, failureMapping: failureMapping)
    }

    /// Calls the real implementation on a stub miss if supplied.
    public init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
                failureReporter: FailureReporter,
                scope: MockScope = MockSession().makeMock(),
                forwarding: AsyncThrowingForwarding<Input, Output, Failure>?,
                failureMapping: (@Sendable (MockIssue) -> Failure)? = nil) {
        dispatch = AsyncThrowingDispatch(id: id, configuration: configuration, failureReporter: failureReporter,
                                         scope: scope, forwarding: forwarding, failureMapping: failureMapping)
    }

    /// Atomically replaces the plan for subsequent admissions. Existing invocations keep their admitted plan.
    @discardableResult
    public func replaceConfiguration(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>) -> RuleRevision {
        dispatch.replaceConfiguration(configuration)
    }

    /// Replaces the plan only while the session is open and has no active invocations,
    /// including calls in earlier epochs. The check and publication share the admission gate.
    @discardableResult
    public func replaceConfigurationIfQuiescent(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>)
        throws(QuiescentConfigurationError) -> RuleRevision {
        try dispatch.replaceConfigurationIfQuiescent(configuration)
    }

    /// Supplies a typed handle for a structural forwarding link.
    public var forwardingTarget: AsyncThrowingForwardingTarget<Input, Output, Failure> {
        AsyncThrowingForwardingTarget(endpoint: self)
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async throws(Failure) -> Output {
        try await dispatch.invoke(input, recording: input, source: source)
    }

    fileprivate func invoke(
        _ input: Input, source: SourceLocation, forwardingPath: [AsyncForwardingInstance]
    ) async throws(Failure) -> Output {
        try await dispatch.invoke(input, recording: input, source: source, forwardingPath: forwardingPath)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase)
    }

    public func verification(matching matcher: Matcher<Input>, phase: CallPhase = .admitted,
                             origin: CallOrigin?) -> Verification<Input> {
        dispatch.verification(matching: matcher, phase: phase, origin: origin)
    }

    public var invocations: [Invocation<Input>] { dispatch.snapshot().calls }
}
