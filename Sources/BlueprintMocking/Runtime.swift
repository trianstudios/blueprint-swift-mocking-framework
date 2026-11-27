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

/// The process-local identity and readable diagnostic name of concrete generic arguments.
public struct EndpointSpecialization: Sendable, Equatable {
    private enum Identity: Sendable, Equatable {
        case scalar(ObjectIdentifier)
        case pack([ObjectIdentifier])
    }

    public let typeName: String
    private let typeIdentity: Identity

    fileprivate init<Argument>(_ type: Argument.Type) {
        self.typeName = String(reflecting: type)
        self.typeIdentity = .scalar(ObjectIdentifier(type))
    }

    fileprivate init(pack types: [Any.Type]) {
        let names = types.map { String(reflecting: $0) }
        self.typeName = "pack(" + names.joined(separator: ", ") + ")"
        self.typeIdentity = .pack(types.map { ObjectIdentifier($0) })
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

    /// Keeps each element's process-local identity and the order and length of the pack.
    /// Even an empty pack is a specialization distinct from a scalar or unspecialized endpoint.
    public init(_ rawValue: String, specializedForPack types: [Any.Type]) {
        self.rawValue = rawValue
        self.specialization = EndpointSpecialization(pack: types)
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
    /// An explicit diagnostic description, if one was supplied or composed.
    public let description: String?

    public init(_ body: @escaping @Sendable (Input) -> Bool) {
        self.init(description: nil, body)
    }

    init(description: String?, _ body: @escaping @Sendable (Input) -> Bool) {
        self.description = description
        self.body = body
    }

    /// Returns the same matcher with a label safe to include in diagnostic output.
    public func named(_ description: String) -> Self {
        Self(description: description, body)
    }

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
    case defaultValueResolution(DefaultValueResolutionError)
}

/// The requested lexical configuration no longer belongs to a live session epoch.
public enum ScopedConfigurationError: Error, Equatable {
    case finishedSession
    case staleScope
    case closedScope

    fileprivate func message(for endpoint: EndpointID) -> String {
        switch self {
        case .finishedSession: "Cannot configure \(endpoint.diagnosticName) in a finished mock session"
        case .staleScope: "Cannot call \(endpoint.diagnosticName) with a stale scoped configuration"
        case .closedScope: "Cannot call \(endpoint.diagnosticName) with a closed scoped configuration"
        }
    }
}

struct ScopedConfigurationKey: Sendable {
    let epoch: SessionEpoch
    let serial: UInt64
}

/// Metadata identifying the complete lexical configuration chain for one endpoint.
/// A handle can be sent to detached work and does not keep the configurations or session alive.
public struct ScopedConfigurationHandle: Sendable {
    public var endpoint: EndpointID { owner.id }
    public let epoch: SessionEpoch
    public var sessionID: SessionID { epoch.sessionID }

    fileprivate let owner: AsyncForwardingInstance
    fileprivate let keys: [ScopedConfigurationKey]
}

/// The handle belongs to another endpoint or another session.
public enum ScopedConfigurationBindingError: Error, Equatable {
    case foreignSession(expected: SessionID, actual: SessionID)
    case foreignEndpoint
}

fileprivate struct ScopedConfigurationToken: Sendable {
    let owner: AsyncForwardingInstance
    let key: ScopedConfigurationKey
}

fileprivate enum ScopedConfigurations {
    // A task that outlives its lexical scope may retain the token, never the rules.
    @TaskLocal static var current: [ScopedConfigurationToken] = []

    static func keys(for owner: AsyncForwardingInstance) -> [ScopedConfigurationKey] {
        current.reversed().compactMap { $0.owner === owner ? $0.key : nil }
    }

    static func withBinding<Value>(
        _ tokens: [ScopedConfigurationToken], isolation: isolated (any Actor)?,
        _ body: () async throws -> Value
    ) async throws -> Value {
        #if compiler(>=6.2)
        let operation: nonisolated(nonsending) () async throws -> Value = { try await body() }
        return try await $current.withValue(tokens, operation: operation)
        #else
        return try await $current.withValue(tokens, operation: body, isolation: isolation)
        #endif
    }
}

fileprivate struct PinnedScopedConfiguration<Configuration: Sendable>: Sendable {
    let key: ScopedConfigurationKey
    let plan: Configuration
}

enum ScenarioRuleLayer: Sendable {
    case base
    case scoped(ScopedConfigurationKey)
}

fileprivate enum ScopedJournalAdmission<Configuration: Sendable>: Sendable {
    case admitted(JournalAdmission, base: Configuration, overlays: [PinnedScopedConfiguration<Configuration>])
    case refused
    case invalidScope(ScopedConfigurationError)
}

typealias Journal<Input: Sendable> = ConfiguredJournal<Input, Void>

final class ConfiguredJournal<Input: Sendable, Configuration: Sendable>: VerificationJournal, SessionJournalRegistration {
    private struct State: Sendable {
        var configuration: Configuration
        var revision = RuleRevision(rawValue: 0)
        var nextID: UInt64 = 0
        // Typed history only appends between epoch resets. IDs continue across resets.
        var discardedCallWatermark: UInt64 = 0
        var calls: [Invocation<Input>] = []
        var projectionEvents: [ProjectionJournalEvent<Input>] = []
        var issues: [MockIssue] = []
        var nextScopedConfigurationID: UInt64 = 0
        var scopedConfigurations: [UInt64: Configuration] = [:]
    }

    private let state: CriticalState<State>
    private let scope: MockScope
    private let tracksProjectionTimeline: ProjectionTimelineFields
    private let forkConfigurationOnReset: (@Sendable (Configuration, Bool) -> Configuration)?
    let endpoint: EndpointID
    private let reporter: FailureReporter

    init(endpoint: EndpointID, reporter: FailureReporter, scope: MockScope,
         configuration: Configuration, tracksProjectionTimeline: ProjectionTimelineFields = [],
         forkConfigurationOnReset: (@Sendable (Configuration, Bool) -> Configuration)? = nil) {
        self.state = CriticalState(State(configuration: configuration))
        self.tracksProjectionTimeline = tracksProjectionTimeline
        self.forkConfigurationOnReset = forkConfigurationOnReset
        self.scope = scope
        self.endpoint = endpoint
        self.reporter = reporter
        scope.session.register(self)
    }

    func admit(_ input: Input) -> (admission: JournalAdmission, configuration: Configuration)? {
        let (result, wake) = scope.session.withLock {
            session -> ((JournalAdmission, Configuration)?, SessionObservationDelivery?) in
            guard scope.admissionRejection(in: session) == nil else { return (nil, nil) }
            let result = state.withLock { history in
                let admission = recordAdmission(input, in: &session, history: &history)
                return (admission, history.configuration)
            }
            return (result, session.observationWake())
        }
        wake?.publish()
        return result
    }

    fileprivate func admit(_ input: Input, scoped keys: [ScopedConfigurationKey])
        -> ScopedJournalAdmission<Configuration> {
        // Lock order is session, then this endpoint. No operation holds two endpoint locks.
        // Only typed plan references are pinned here. Matchers and reservation run after release.
        let (result, wake) = scope.session.withLock {
            session -> (ScopedJournalAdmission<Configuration>, SessionObservationDelivery?) in
            guard scope.admissionRejection(in: session) == nil else { return (.refused, nil) }
            let result = state.withLock { state -> ScopedJournalAdmission<Configuration> in
                let overlays: [PinnedScopedConfiguration<Configuration>]
                switch Self.pinScopedConfigurations(keys, epoch: session.epoch, state: state) {
                case .success(let plans): overlays = plans
                case .failure(let error): return .invalidScope(error)
                }
                let admission = recordAdmission(input, in: &session, history: &state)
                return .admitted(admission, base: state.configuration, overlays: overlays)
            }
            if case .admitted = result { return (result, session.observationWake()) }
            return (result, nil)
        }
        wake?.publish()
        return result
    }

    // The session and endpoint locks are held in that order by the caller.
    private func recordAdmission(
        _ input: Input, in session: inout MockSession.State, history: inout State
    ) -> JournalAdmission {
        history.nextID += 1
        let id = history.nextID
        let event = session.admit(mockID: scope.id, endpoint: endpoint, configurationRevision: history.revision)
        history.calls.append(Invocation(id: id, input: input, configurationRevision: history.revision,
                                        sessionInvocationID: event.invocationID, epoch: event.epoch,
                                        phase: .admitted, origin: nil))
        if !tracksProjectionTimeline.isEmpty {
            history.projectionEvents.append(ProjectionJournalEvent(
                ordinal: event.ordinal, elapsed: event.elapsed, invocationID: event.invocationID, change: .admitted
            ))
        }
        return JournalAdmission(id: id, event: event)
    }

    private static func pinScopedConfigurations(
        _ keys: [ScopedConfigurationKey], epoch: SessionEpoch, state: State
    ) -> Result<[PinnedScopedConfiguration<Configuration>], ScopedConfigurationError> {
        var plans: [PinnedScopedConfiguration<Configuration>] = []
        plans.reserveCapacity(keys.count)
        for key in keys {
            guard key.epoch == epoch else { return .failure(.staleScope) }
            guard let plan = state.scopedConfigurations[key.serial] else { return .failure(.closedScope) }
            plans.append(PinnedScopedConfiguration(key: key, plan: plan))
        }
        return .success(plans)
    }

    private func requireOpenScope(in session: MockSession.State) throws(ScopedConfigurationError) {
        switch scope.admissionRejection(in: session) {
        case .finished: throw .finishedSession
        case .staleTypeScope: throw .staleScope
        case nil: break
        }
    }

    fileprivate func validateScopedConfiguration(_ keys: [ScopedConfigurationKey]) throws(ScopedConfigurationError) {
        try scope.session.withLock { session throws(ScopedConfigurationError) in
            try requireOpenScope(in: session)
            try state.withLock { state throws(ScopedConfigurationError) in
                _ = try Self.pinScopedConfigurations(keys, epoch: session.epoch, state: state).get()
            }
        }
    }

    fileprivate func openScopedConfiguration(_ configuration: Configuration, parents: [ScopedConfigurationKey])
        throws(ScopedConfigurationError) -> ScopedConfigurationKey {
        try scope.session.withLock { session throws(ScopedConfigurationError) in
            try requireOpenScope(in: session)
            return try state.withLock { state throws(ScopedConfigurationError) in
                _ = try Self.pinScopedConfigurations(parents, epoch: session.epoch, state: state).get()
                state.nextScopedConfigurationID += 1
                let serial = state.nextScopedConfigurationID
                state.scopedConfigurations[serial] = configuration
                return ScopedConfigurationKey(epoch: session.epoch, serial: serial)
            }
        }
    }

    fileprivate func closeScopedConfiguration(_ key: ScopedConfigurationKey) {
        let retired = scope.session.withLock { session in
            guard key.epoch == session.epoch else { return nil as Configuration? }
            return state.withLock { $0.scopedConfigurations.removeValue(forKey: key.serial) }
        }
        withExtendedLifetime(retired) {}
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

    func replaceConfigurationWhenQuiescent(_ configuration: Configuration, within timeout: Duration)
        async throws -> RuleRevision {
        try await scope.session.replaceWhenQuiescent(within: timeout, expectedEpoch: scope.expectedEpoch) {
            clock, deadline in
            self.state.withLock { state -> (RuleRevision, any Sendable)? in
                // Both admission and endpoint locks are held. A continuous deadline
                // can elapse while this request waits to acquire the endpoint lock.
                guard clock.elapsed < deadline else { return nil }
                let (revision, retired) = Self.swapConfiguration(configuration, in: &state)
                return (revision, retired)
            }
        }
    }

    private func swapConfiguration(_ configuration: Configuration) -> (RuleRevision, Configuration) {
        state.withLock { Self.swapConfiguration(configuration, in: &$0) }
    }

    private static func swapConfiguration(
        _ configuration: Configuration, in state: inout State
    ) -> (RuleRevision, Configuration) {
        let retired = state.configuration
        let revision = RuleRevision(rawValue: state.revision.rawValue + 1)
        state.configuration = configuration
        state.revision = revision
        return (revision, retired)
    }

    func recordCancellationRequest(for admission: JournalAdmission) {
        let id = admission.event.invocationID
        let (wake, delayedAnswer) = scope.session.withLock {
            ($0.recordCancellationRequest(for: id), $0.cancelDelayedAnswer(for: id))
        }
        wake?.publish()
        delayedAnswer?.publish()
    }

    func update(_ admission: JournalAdmission, replacing input: Input) {
        let (retired, wake) = scope.session.withLock { session -> (Input?, SessionObservationDelivery?) in
            guard admission.event.epoch == session.epoch else { return (nil, nil) }
            let retired = state.withLock { history in
                let index = Int(admission.id - history.discardedCallWatermark - 1)
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
        _ admission: JournalAdmission, phase: CallPhase, origin: CallOrigin? = nil, replacing input: Input? = nil,
        scenarioCompletion: (layer: ScenarioRuleLayer, transition: AsyncScenarioCompletion)? = nil
    ) {
        let (delivery, wake, retired) = scope.session.withLock { session in
            let epoch = session.epoch
            if let scenarioCompletion, admission.event.epoch == epoch {
                // Completing the last invocation may publish a queued replacement
                // that takes the same journal lock. Release this lock first.
                state.withLock { endpoint in
                    switch scenarioCompletion.layer {
                    case .base:
                        guard endpoint.revision == admission.event.configurationRevision else { return }
                    case .scoped(let key):
                        guard key.epoch == epoch, endpoint.scopedConfigurations[key.serial] != nil else { return }
                    }
                    scenarioCompletion.transition.commitIfCurrent()
                }
            }
            let (terminal, ready) = session.complete(admission.event.invocationID, phase: phase, origin: origin)
            var retired: Input? = nil
            if admission.event.epoch == session.epoch {
                retired = state.withLock { history -> Input? in
                    let index = Int(admission.id - history.discardedCallWatermark - 1)
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
    func discardHistory(restartingSequences: Bool) -> any Sendable {
        state.withLock { state in
            let retiredHistory = (state.calls, state.projectionEvents)
            state.discardedCallWatermark = state.nextID
            state.calls = []
            state.projectionEvents = []
            var retiredConfiguration: Configuration?
            if let forkConfigurationOnReset {
                // Detached admissions can still reserve answers from their saved plan.
                let previous = state.configuration
                state.configuration = forkConfigurationOnReset(previous, restartingSequences)
                retiredConfiguration = previous
            }
            let retiredScopes = state.scopedConfigurations
            state.scopedConfigurations = [:]
            return (retiredHistory, retiredConfiguration, retiredScopes)
        }
    }

    // Session finish takes the same lock order and releases retired plans after leaving the gate.
    func discardCapturesOnFinish() -> (any Sendable)? {
        state.withLock { state in
            guard !state.scopedConfigurations.isEmpty else { return nil }
            let retired = state.scopedConfigurations
            state.scopedConfigurations = [:]
            return retired
        }
    }

    fileprivate func reportInvalidScopedCall(
        _ error: ScopedConfigurationError, source: SourceLocation, terminating: Bool
    ) -> MockIssue {
        let closedEpoch = scope.session.withLock { $0.isFinished ? $0.epoch : nil }
        let issue = MockIssue(kind: .unexpectedCall, endpoint: endpoint, message: error.message(for: endpoint),
                              source: source, watermark: state.withLock { $0.nextID })
        if !scope.bufferOrphan(issue, closedEpoch: closedEpoch, terminating: terminating) {
            report(issue)
        }
        return issue
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

    func reportExhaustedSequence(
        _ admission: JournalAdmission, phase: CallPhase? = nil, source: SourceLocation
    ) -> MockIssue {
        reportUnansweredCall(admission, phase: phase, source: source, reason: .exhaustedSequence)
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
        case .defaultValueResolution(let error):
            kind = .unexpectedCall
            message = "\(error.diagnostic) for \(endpoint.diagnosticName)"
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
                message: MatcherDescription.countFailure(failure, description: matcher.description),
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
    private let defaultValues: DefaultValueRegistry?

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
    public convenience init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                            failureReporter: FailureReporter,
                            scope: MockScope = MockSession().makeMock(),
                            forwarding: (@Sendable (Input) -> Output)?,
                            fallback: (@Sendable (MockIssue) -> Output)? = nil) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: forwarding, fallback: fallback, defaultValues: nil)
    }

    /// Uses explicitly registered typed defaults on a stub and forwarding miss.
    public convenience init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                            failureReporter: FailureReporter,
                            scope: MockScope = MockSession().makeMock(),
                            forwarding: (@Sendable (Input) -> Output)? = nil,
                            defaultValues: DefaultValueRegistry) {
        self.init(id: id, configuration: configuration, failureReporter: failureReporter,
                  scope: scope, forwarding: forwarding, fallback: nil, defaultValues: defaultValues)
    }

    private init(id: EndpointID, configuration: SyncConfiguration<Input, Output>,
                 failureReporter: FailureReporter, scope: MockScope,
                 forwarding: (@Sendable (Input) -> Output)?,
                 fallback: (@Sendable (MockIssue) -> Output)?,
                 defaultValues: DefaultValueRegistry?) {
        configuration.validateCaptureSession(scope.session.id)
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.forwarding = forwarding
        self.fallback = fallback
        self.defaultValues = defaultValues
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
        guard let defaultValues else {
            return journal.resolveMissingNonthrowingCall(admission, source: source, fallback: fallback)
        }
        do throws(DefaultValueResolutionError) {
            let result = try defaultValues.require(Output.self)
            journal.complete(admission, phase: .returned)
            return result
        } catch {
            let issue = journal.reportUnansweredCall(admission, phase: .terminated, source: source,
                                                    reason: .defaultValueResolution(error))
            fatalError(issue.message)
        }
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

private enum AsyncThrowingStepAnswer<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    case immediate(AsyncAnswer<Input, Output, Failure>)
    case delayedReturn(Output, delay: Duration, cancellation: Failure)

    func perform(_ input: Input, in session: MockSession, invocationID: SessionInvocationID)
        async -> Result<Output, Failure> {
        switch self {
        case .immediate(let answer):
            return await answer(input)
        case .delayedReturn(let output, let delay, let cancellation):
            switch await session.waitForDelayedAnswer(invocationID, after: delay) {
            case .elapsed: return .success(output)
            case .cancelled: return .failure(cancellation)
            }
        }
    }
}

/// A legal step for a Sendable async endpoint's exact input, result, and thrown error.
public struct AsyncThrowingSequenceStep<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let answer: AsyncThrowingStepAnswer<Input, Output, Failure>

    public static func returning(_ output: Output) -> Self {
        Self(answer: .immediate { _ in .success(output) })
    }

    /// Reserves this step once, then waits on the owning session's clock.
    /// The positive delay starts when the reserved call registers its wait,
    /// after any winning-rule capture. Cancellation before the wait is acquired
    /// throws the configured failure. The call resumes on its own task.
    public static func returning(_ output: Output, after delay: Duration, onCancellation failure: Failure) -> Self {
        precondition(delay > .zero, "A delayed sequence step needs a positive duration")
        return Self(answer: .delayedReturn(output, delay: delay, cancellation: failure))
    }

    public static func throwing(_ failure: Failure) -> Self {
        Self(answer: .immediate { _ in .failure(failure) })
    }

    public static func answering(_ body: @escaping @Sendable (Input) async throws(Failure) -> Output) -> Self {
        Self(answer: .immediate { input in
            do throws(Failure) { return .success(try await body(input)) }
            catch { return .failure(error) }
        })
    }
}

fileprivate struct AsyncRuleBehavior<Input: Sendable, Plan: Sendable>: Sendable {
    let plan: Plan
    let capture: WinningRuleCapture<Input>?
}

private enum PlannedAsyncThrowingRulePlan<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    case answers(PlannedAnswer<AsyncThrowingStepAnswer<Input, Output, Failure>>)
    case scenario(AsyncScenarioPlan<Input, Output, Failure>)

    func publish() -> PublishedAsyncThrowingRulePlan<Input, Output, Failure> {
        switch self {
        case .answers(let plan): .answers(plan.publish())
        case .scenario(let plan): .scenario(PublishedAsyncScenario(plan: plan))
        }
    }
}

private enum AsyncThrowingRuleReservation<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    case reserved(AsyncThrowingStepAnswer<Input, Output, Failure>, completion: AsyncScenarioCompletion?)
    case conflict(Failure)
    case exhausted
}

private enum PublishedAsyncThrowingRulePlan<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    case answers(PublishedAnswer<AsyncThrowingStepAnswer<Input, Output, Failure>>)
    case scenario(PublishedAsyncScenario<Input, Output, Failure>)

    func reserve(_ input: Input, in session: MockSession) -> AsyncThrowingRuleReservation<Input, Output, Failure> {
        switch self {
        case .answers(let plan):
            guard let answer = plan.reserve(in: session) else { return .exhausted }
            return .reserved(answer, completion: nil)
        case .scenario(let scenario):
            switch scenario.reserve(input, in: session) {
            case .reserved(let step, let completion): return .reserved(step.answer, completion: completion)
            case .conflict(let failure): return .conflict(failure)
            }
        }
    }

    func fork(restartingSequences: Bool) -> Self {
        switch self {
        case .answers(let plan): .answers(plan.forkSequence(restarting: restartingSequences))
        case .scenario(let scenario): .scenario(scenario.fork())
        }
    }
}

fileprivate typealias PlannedAsyncThrowingRule<Input: Sendable, Output: Sendable, Failure: Error> =
    Rule<Input, AsyncRuleBehavior<Input, PlannedAsyncThrowingRulePlan<Input, Output, Failure>>>

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
    let rules: [Rule<Input, AsyncRuleBehavior<Input, PublishedAsyncThrowingRulePlan<Input, Output, Failure>>>]

    func forkSequences(restarting: Bool) -> Self {
        Self(rules: rules.map { rule in
            Rule(matcher: rule.matcher, answer: AsyncRuleBehavior(
                plan: rule.answer.plan.fork(restartingSequences: restarting), capture: rule.answer.capture))
        })
    }
}

public final class AsyncThrowingStubbing<Input: Sendable, Output: Sendable, Failure: Error> {
    private var rules: [(priority: Int, rule: PlannedAsyncThrowingRule<Input, Output, Failure>)] = []
    private var finished = false
    public init() {}
    public func matching(_ matcher: Matcher<Input>) -> AsyncThrowingStub<Input, Output, Failure> {
        AsyncThrowingStub(owner: self, matcher: matcher, capture: nil, rulePriority: 0)
    }
    fileprivate func add(
        _ matcher: Matcher<Input>, _ answer: PlannedAsyncThrowingRulePlan<Input, Output, Failure>,
        capture: WinningRuleCapture<Input>?, priority: Int
    ) {
        precondition(!finished, "Setup is already published; live reconfiguration is not implemented")
        let rule = Rule(matcher: matcher, answer: AsyncRuleBehavior(plan: answer, capture: capture))
        rules.append((priority, rule))
    }
    public func finish() -> AsyncThrowingConfiguration<Input, Output, Failure> {
        precondition(!finished, "Setup is already published")
        finished = true
        // A stable ascending sort preserves registration order among equal priorities.
        // Dispatch already scans each independent layer in reverse.
        let ordered = rules.sorted { $0.priority < $1.priority }.map { $0.rule }
        return AsyncThrowingConfiguration(rules: ordered)
    }
}
public struct AsyncThrowingStub<Input: Sendable, Output: Sendable, Failure: Error> {
    fileprivate let owner: AsyncThrowingStubbing<Input, Output, Failure>
    fileprivate let matcher: Matcher<Input>
    fileprivate let capture: WinningRuleCapture<Input>?
    fileprivate let rulePriority: Int

    /// Sets this rule's priority within its own configuration. Rules default to zero.
    /// Matching rules with higher priorities take precedence. Ties prefer the latest registration.
    public func priority(_ value: Int) -> Self {
        Self(owner: owner, matcher: matcher, capture: capture, rulePriority: value)
    }

    /// Projects the argument once after this rule reserves an answer and before it executes.
    /// A second call replaces the policy on the returned descriptor. The captor and
    /// endpoint must use the same session at initialization and configuration replacement.
    public func capturing<Value: Sendable>(
        into captor: ArgumentCaptor<Value>, projecting projection: @escaping @Sendable (Input) -> Value
    ) -> Self {
        AsyncThrowingStub(owner: owner, matcher: matcher,
                          capture: WinningRuleCapture(captor: captor, projecting: projection),
                          rulePriority: rulePriority)
    }

    public func willReturn(_ output: Output) {
        owner.add(matcher, .answers(.single(AsyncThrowingSequenceStep<Input, Output, Failure>.returning(output).answer)),
                  capture: capture, priority: rulePriority)
    }
    public func willThrow(_ error: Failure) {
        owner.add(matcher, .answers(.single(AsyncThrowingSequenceStep<Input, Output, Failure>.throwing(error).answer)),
                  capture: capture, priority: rulePriority)
    }
    public func willAnswer(_ answer: @escaping @Sendable (Input) async throws(Failure) -> Output) {
        owner.add(matcher, .answers(.single(AsyncThrowingSequenceStep<Input, Output, Failure>.answering(answer).answer)),
                  capture: capture, priority: rulePriority)
    }

    /// Reserves one step for each matching call. An exhausted finite sequence
    /// reports a failure instead of falling through to an earlier rule.
    public func willSequence(
        _ first: AsyncThrowingSequenceStep<Input, Output, Failure>,
        _ remaining: AsyncThrowingSequenceStep<Input, Output, Failure>...,
        policy: StubSequencePolicy = .finite
    ) {
        owner.add(matcher, .answers(.sequence([first.answer] + remaining.map(\.answer), policy)),
                  capture: capture, priority: rulePriority)
    }

    /// Uses a finite state machine owned by this published rule. Transition guards
    /// work like ordinary matchers and are evaluated before state selection.
    /// If multiple guards match the current state, the last declaration wins.
    /// A missing transition throws the configured failure without falling through.
    /// History reset carries the current state forward; installing a new plan starts
    /// from its initial state.
    public func willScenario(
        initial: String, transitions: [AsyncThrowingScenarioTransition<Input, Output, Failure>],
        onConflict failure: Failure
    ) {
        precondition(!initial.isEmpty && !transitions.isEmpty,
                     "A scenario requires a named initial state and at least one transition")
        let plan = AsyncScenarioPlan(initial: initial, transitions: transitions, conflict: failure)
        owner.add(matcher, .scenario(plan), capture: capture, priority: rulePriority)
    }
}

/// Shared typed dispatch for raw and projection-only histories.
struct AsyncThrowingDispatch<Input: Sendable, Output: Sendable, Failure: Error, History: Sendable>: Sendable {
    private let journal: ConfiguredJournal<History, PublishedAsyncThrowingConfiguration<Input, Output, Failure>>
    private let failureMapping: (@Sendable (MockIssue) -> Failure)?
    private let forwarding: AsyncThrowingForwarding<Input, Output, Failure>?
    private let forwardingInstance: AsyncForwardingInstance
    private let session: MockSession

    init(id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
         failureReporter: FailureReporter, scope: MockScope,
         forwarding: AsyncThrowingForwarding<Input, Output, Failure>? = nil,
         failureMapping: (@Sendable (MockIssue) -> Failure)?, tracksProjectionTimeline: ProjectionTimelineFields = []) {
        self.session = scope.session
        self.forwarding = forwarding
        self.forwardingInstance = AsyncForwardingInstance(id: id)
        self.failureMapping = failureMapping
        journal = ConfiguredJournal(endpoint: id, reporter: failureReporter, scope: scope,
                                    configuration: configuration.publish(for: scope.session.id),
                                    tracksProjectionTimeline: tracksProjectionTimeline,
                                    forkConfigurationOnReset: { $0.forkSequences(restarting: $1) })
    }

    func replaceConfiguration(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>) -> RuleRevision {
        journal.replaceConfiguration(configuration.publish(for: session.id))
    }

    func replaceConfigurationIfQuiescent(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>)
        throws(QuiescentConfigurationError) -> RuleRevision {
        try journal.replaceConfigurationIfQuiescent(configuration.publish(for: session.id))
    }

    func replaceConfigurationWhenQuiescent(
        _ configuration: AsyncThrowingConfiguration<Input, Output, Failure>, within timeout: Duration
    ) async throws -> RuleRevision {
        try await journal.replaceConfigurationWhenQuiescent(configuration.publish(for: session.id), within: timeout)
    }

    func withScopedConfiguration<Value>(
        _ configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async throws -> Value {
        let plan = configuration.publish(for: session.id)
        let key = try journal.openScopedConfiguration(plan, parents: ScopedConfigurations.keys(for: forwardingInstance))
        defer { journal.closeScopedConfiguration(key) }
        let token = ScopedConfigurationToken(owner: forwardingInstance, key: key)
        return try await ScopedConfigurations.withBinding(ScopedConfigurations.current + [token],
                                                           isolation: isolation, body)
    }

    func currentScopedConfiguration() throws(ScopedConfigurationError) -> ScopedConfigurationHandle? {
        let keys = ScopedConfigurations.current.compactMap { $0.owner === forwardingInstance ? $0.key : nil }
        guard let current = keys.last else { return nil }
        try journal.validateScopedConfiguration(keys)
        return ScopedConfigurationHandle(epoch: current.epoch, owner: forwardingInstance, keys: keys)
    }

    func withScopedConfiguration<Value>(
        _ handle: ScopedConfigurationHandle,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async throws -> Value {
        guard handle.sessionID == session.id else {
            throw ScopedConfigurationBindingError.foreignSession(expected: session.id, actual: handle.sessionID)
        }
        guard handle.owner === forwardingInstance else { throw ScopedConfigurationBindingError.foreignEndpoint }
        try journal.validateScopedConfiguration(handle.keys)

        let unrelated = ScopedConfigurations.current.filter { $0.owner !== forwardingInstance }
        let rebound = handle.keys.map { ScopedConfigurationToken(owner: forwardingInstance, key: $0) }
        return try await ScopedConfigurations.withBinding(unrelated + rebound, isolation: isolation, body)
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
        let admission: JournalAdmission
        let configuration: PublishedAsyncThrowingConfiguration<Input, Output, Failure>
        let overlays: [PinnedScopedConfiguration<PublishedAsyncThrowingConfiguration<Input, Output, Failure>>]
        switch journal.admit(initialHistory, scoped: ScopedConfigurations.keys(for: forwardingInstance)) {
        case .admitted(let admitted, let base, let scoped):
            admission = admitted
            configuration = base
            overlays = scoped
        case .refused:
            let issue = journal.reportFinishedCall(source: source, terminating: failureMapping == nil)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        case .invalidScope(let error):
            let issue = journal.reportInvalidScopedCall(error, source: source, terminating: failureMapping == nil)
            if let failureMapping { throw failureMapping(issue) }
            fatalError(issue.message)
        }
        let result = await withTaskCancellationHandler {
            await invokeAdmitted(
                input, admission: admission, configuration: configuration, overlays: overlays,
                initialHistory: initialHistory, source: source, forwardingPath: forwardingPath,
                argumentProjection: argumentProjection, completionProjection: completionProjection
            )
        } onCancel: {
            journal.recordCancellationRequest(for: admission)
        }
        return try result.get()
    }

    private func invokeAdmitted(
        _ input: Input, admission: JournalAdmission,
        configuration: PublishedAsyncThrowingConfiguration<Input, Output, Failure>,
        overlays: [PinnedScopedConfiguration<PublishedAsyncThrowingConfiguration<Input, Output, Failure>>],
        initialHistory: History, source: SourceLocation, forwardingPath: [AsyncForwardingInstance],
        argumentProjection: @Sendable (Input) -> History?,
        completionProjection: @Sendable (History, Output?) -> History?
    ) async -> Result<Output, Failure> {
        defer { withExtendedLifetime((configuration, overlays)) {} }

        // User projections, rule matching, answer execution, and error mapping all run
        // after admission, outside journal and sequence locks.
        let projected = argumentProjection(input)
        if let projected { journal.update(admission, replacing: projected) }
        let history = projected ?? initialHistory

        let layers = overlays.map { (plan: $0.plan, identity: ScenarioRuleLayer.scoped($0.key)) }
            + [(plan: configuration, identity: .base)]
        let winner = layers.lazy.flatMap { layer in
            layer.plan.rules.reversed().lazy.map { (rule: $0, layer: layer.identity) }
        }.first { $0.rule.matcher.matches(input) }
        let outcome: AsyncDispatchOutcome<Output, Failure>
        var scenarioCompletion: (layer: ScenarioRuleLayer, transition: AsyncScenarioCompletion)?
        if let winner {
            switch winner.rule.answer.plan.reserve(input, in: session) {
            case .reserved(let answer, let completion):
                scenarioCompletion = completion.map { (layer: winner.layer, transition: $0) }
                winner.rule.answer.capture?.publish(input, admission.event)
                let result = await answer.perform(input, in: session, invocationID: admission.event.invocationID)
                outcome = .answered(result, origin: nil)
            case .conflict(let failure):
                outcome = .answered(.failure(failure), origin: nil)
            case .exhausted:
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
                admission, phase: .returned, origin: origin,
                replacing: completionProjection(history, .some(output)), scenarioCompletion: scenarioCompletion
            )
            return .success(output)
        case .answered(.failure(let error), let origin):
            journal.complete(admission, phase: .threw, origin: origin, replacing: completionProjection(history, nil))
            return .failure(error)
        case .unanswered(let reason):
            if let failureMapping {
                let issue = journal.reportUnansweredCall(admission, source: source, reason: reason)
                let error = failureMapping(issue)
                journal.complete(admission, phase: .threw, replacing: completionProjection(history, nil))
                return .failure(error)
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

    /// Installs the plan at a zero-active session boundary strictly before the timeout
    /// on the session clock. The published revision is visible to the next admission.
    /// A timeout must be positive. A closed or stale scope, deadline, or cancellation
    /// ends an uncommitted request. An installed revision remains the result after cancellation.
    /// Call from outside any invocation whose completion this request will await.
    @discardableResult
    public func replaceConfigurationWhenQuiescent(
        _ configuration: AsyncThrowingConfiguration<Input, Output, Failure>, within timeout: Duration
    ) async throws -> RuleRevision {
        try await dispatch.replaceConfigurationWhenQuiescent(configuration, within: timeout)
    }

    /// Runs an operation with an endpoint-local rule overlay. The innermost matching
    /// configuration wins, followed by its enclosing scopes and the base rules.
    /// Child tasks inherit the binding. Detached tasks can rebind an explicitly captured handle.
    /// A rule whose sequence is exhausted reports the failure without falling through.
    /// This operation does not replace the base configuration or its revision.
    public func withScopedConfiguration<Value>(
        _ configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        try await dispatch.withScopedConfiguration(configuration, isolation: isolation, operation)
    }

    /// Captures this endpoint's current lexical configuration chain for explicit transport.
    /// Returns nil when this task has no binding. A stale or closed binding throws.
    public func currentScopedConfiguration() throws(ScopedConfigurationError) -> ScopedConfigurationHandle? {
        try dispatch.currentScopedConfiguration()
    }

    /// Temporarily installs the captured chain for this endpoint while preserving other bindings.
    /// The originating scopes must be active at rebinding. Every call also validates its scope at admission.
    public func withScopedConfiguration<Value>(
        _ handle: ScopedConfigurationHandle,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        try await dispatch.withScopedConfiguration(handle, isolation: isolation, operation)
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
