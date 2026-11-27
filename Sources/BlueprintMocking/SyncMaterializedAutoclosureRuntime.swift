/// The normal arguments and the single value produced by an admitted autoclosure.
public struct MaterializedAutoclosureArguments<Input: Sendable, Value: Sendable>: Sendable {
    public let input: Input
    public let value: Value
}

public typealias SyncMaterializedAutoclosureStubbing<Input: Sendable, Value: Sendable, Output: Sendable> =
    SyncStubbing<MaterializedAutoclosureArguments<Input, Value>, Output>

public typealias SyncMaterializedAutoclosureStub<Input: Sendable, Value: Sendable, Output: Sendable> =
    SyncStub<MaterializedAutoclosureArguments<Input, Value>, Output>

public struct SyncMaterializedAutoclosureVerification<Input: Sendable, Value: Sendable>: Sendable {
    public typealias Arguments = MaterializedAutoclosureArguments<Input, Value>

    fileprivate let journal: Journal<ProjectedFields<Arguments, Void>>
    fileprivate let matcher: Matcher<Arguments>
    fileprivate let phase: CallPhase

    /// Reads retained values at the verification cut. A matching field that is
    /// still pending makes the result incomplete, even when the count permits zero.
    public func wasCalled(_ count: CallCount) -> ProjectedVerificationResult<Arguments> {
        ProjectedInvocationHistory(journal.snapshot()).verify(count, matchingArgument: matcher, phase: phase)
    }
}

/// An explicit exactly-once mode for a synchronous nonthrowing autoclosure.
/// Use immutable values when verification must preserve the state at evaluation.
public final class SyncMaterializedAutoclosureEndpoint<
    Input: Sendable, Value: Sendable, Output: Sendable
>: Sendable {
    public typealias Arguments = MaterializedAutoclosureArguments<Input, Value>

    private let configuration: SyncConfiguration<Arguments, Output>
    private let journal: Journal<ProjectedFields<Arguments, Void>>
    private let fallback: (@Sendable (MockIssue) -> Output)?

    public init(
        id: EndpointID, configuration: SyncConfiguration<Arguments, Output>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        fallback: (@Sendable (MockIssue) -> Output)? = nil
    ) {
        configuration.validateCaptureSession(scope.session.id)
        self.configuration = configuration
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
        self.fallback = fallback
    }

    /// Evaluates only after admission. The thunk runs outside both locks, and
    /// neither it nor any callable wrapper becomes part of the journal or setup.
    public func invoke(_ input: Input, _ evaluate: () -> Value, source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(.init(argument: .pending, result: .pending)) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: fallback)
        }
        let arguments = Arguments(input: input, value: evaluate())
        journal.update(admission, replacing: .init(argument: .value(arguments), result: .pending))

        let output: Output
        if let answer = configuration.answer(matching: arguments, recording: admission.event) {
            output = answer(arguments)
        } else {
            guard let fallback else {
                journal.complete(admission, phase: .terminated,
                                 replacing: .init(argument: .value(arguments), result: .unavailable))
                let issue = journal.reportMissingCall(admission, source: source)
                fatalError(issue.message)
            }
            output = fallback(journal.reportMissingCall(admission, source: source))
        }
        journal.complete(admission, phase: .returned,
                         replacing: .init(argument: .value(arguments), result: .value(())))
        return output
    }

    public func verification(
        matching matcher: Matcher<Arguments>, phase: CallPhase = .admitted
    ) -> SyncMaterializedAutoclosureVerification<Input, Value> {
        SyncMaterializedAutoclosureVerification(journal: journal, matcher: matcher, phase: phase)
    }
}
