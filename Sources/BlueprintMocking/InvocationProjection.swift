/// The status of a retained field at the moment a projected history was read.
public enum ProjectedValue<Value: Sendable>: Sendable {
    /// Projection or answer execution has not finished yet.
    case pending
    /// The value selected by the projection.
    case value(Value)
    /// The invocation ended without producing this field.
    case unavailable
}

extension ProjectedValue: Equatable where Value: Equatable {}

/// Selects the values retained by a projected endpoint. Use immutable snapshots
/// such as an ID or redacted summary for history that must remain stable.
public struct InvocationProjection<Input: Sendable, Output: Sendable,
                                   Argument: Sendable, Result: Sendable>: Sendable {
    let argument: @Sendable (Input) -> Argument
    let result: @Sendable (Output) -> Result

    public init(
        argument: @escaping @Sendable (Input) -> Argument,
        result: @escaping @Sendable (Output) -> Result
    ) {
        self.argument = argument
        self.result = result
    }
}

/// One invocation's projected fields and lifecycle metadata.
public struct ProjectedInvocation<Argument: Sendable, Result: Sendable>: Sendable {
    public let argument: ProjectedValue<Argument>
    public let result: ProjectedValue<Result>
    public let phase: CallPhase
    public let id: UInt64
    public let sessionInvocationID: SessionInvocationID
    public let epoch: SessionEpoch
    public let configurationRevision: RuleRevision
}

/// The projected records retained by an endpoint in the current session epoch.
public struct ProjectedInvocationHistory<Argument: Sendable, Result: Sendable>: Sendable {
    public let calls: [ProjectedInvocation<Argument, Result>]
    public let watermark: UInt64
    public let epoch: SessionEpoch

    init(_ snapshot: JournalSnapshot<ProjectedFields<Argument, Result>>) {
        calls = snapshot.calls.map { invocation in
            ProjectedInvocation(
                argument: invocation.input.argument, result: invocation.input.result,
                phase: invocation.phase, id: invocation.id,
                sessionInvocationID: invocation.sessionInvocationID, epoch: invocation.epoch,
                configurationRevision: invocation.configurationRevision
            )
        }
        watermark = snapshot.watermark
        epoch = snapshot.epoch
    }
}

struct ProjectedFields<Argument: Sendable, Result: Sendable>: Sendable {
    let argument: ProjectedValue<Argument>
    let result: ProjectedValue<Result>
}

/// A synchronous endpoint whose history retains the supplied projections only.
/// Matchers and answers receive the original input during the call.
public final class ProjectedSyncEndpoint<Input: Sendable, Output: Sendable,
                                         Argument: Sendable, Result: Sendable>: Sendable {
    private let configuration: SyncConfiguration<Input, Output>
    private let projection: InvocationProjection<Input, Output, Argument, Result>
    private let fallback: (@Sendable (MockIssue) -> Output)?
    let projectedJournal: Journal<ProjectedFields<Argument, Result>>

    public init(
        id: EndpointID, configuration: SyncConfiguration<Input, Output>,
        projection: InvocationProjection<Input, Output, Argument, Result>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        configuration.validateCaptureSession(scope.session.id)
        self.configuration = configuration
        self.projection = projection
        self.fallback = fallback
        projectedJournal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = projectedJournal.begin(.init(argument: .pending, result: .pending)) else {
            return projectedJournal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        let argument = ProjectedValue.value(projection.argument(input))
        projectedJournal.update(admission, replacing: .init(argument: argument, result: .pending))

        let output: Output
        if let answer = configuration.answer(matching: input, recording: admission.event) {
            output = answer(input)
        } else {
            guard let fallback else {
                projectedJournal.complete(admission, phase: .terminated,
                                          replacing: .init(argument: argument, result: .unavailable))
                let issue = projectedJournal.reportMissingCall(admission, source: source)
                fatalError(issue.message)
            }
            let issue = projectedJournal.reportMissingCall(admission, source: source)
            output = fallback(issue)
        }

        let result = ProjectedValue.value(projection.result(output))
        projectedJournal.complete(admission, phase: .returned,
                                  replacing: .init(argument: argument, result: result))
        return output
    }

    public func projectedHistory() -> ProjectedInvocationHistory<Argument, Result> {
        ProjectedInvocationHistory(projectedJournal.snapshot())
    }
}
