#if compiler(>=6.4)
public typealias BorrowedSpanSyncStubbing<Metadata: Sendable, Output: Sendable> = SyncStubbing<Metadata, Output>
public typealias BorrowedSpanSyncStub<Metadata: Sendable, Output: Sendable> = SyncStub<Metadata, Output>

public struct BorrowedSpanSyncVerification<Metadata: Sendable>: Sendable {
    fileprivate let journal: Journal<ProjectedFields<Metadata, Void>>
    fileprivate let matcher: Matcher<Metadata>
    fileprivate let phase: CallPhase

    /// A pending projection prevents a complete value-based assertion.
    public func wasCalled(_ count: CallCount) -> ProjectedVerificationResult<Metadata> {
        ProjectedInvocationHistory(journal.snapshot()).verify(count, matchingArgument: matcher, phase: phase)
    }
}

/// Runs a synchronous projection of the borrowed byte view after admission.
/// Rules, answers, and history receive only the owned metadata.
public final class BorrowedSpanSyncEndpoint<Metadata: Sendable, Output: Sendable>: Sendable {
    private let configuration: SyncConfiguration<Metadata, Output>
    private let projectingSpan: @Sendable (borrowing Swift.Span<Swift.UInt8>) -> Metadata
    private let journal: Journal<ProjectedFields<Metadata, Void>>

    public init(
        id: EndpointID, configuration: SyncConfiguration<Metadata, Output>,
        projectingSpan: @escaping @Sendable (borrowing Swift.Span<Swift.UInt8>) -> Metadata,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()
    ) {
        configuration.validateCaptureSession(scope.session.id)
        self.configuration = configuration
        self.projectingSpan = projectingSpan
        self.journal = Journal(endpoint: id, reporter: failureReporter, scope: scope)
    }

    public func invoke(_ input: borrowing Swift.Span<Swift.UInt8>,
                       source: SourceLocation = SourceLocation()) -> Output {
        guard let admission = journal.begin(.init(argument: .pending, result: .pending)) else {
            return journal.resolveFinishedNonthrowingCall(source: source, fallback: nil)
        }

        let metadata = projectingSpan(input)
        let argument = ProjectedValue.value(metadata)
        journal.update(admission, replacing: .init(argument: argument, result: .pending))
        guard let answer = configuration.answer(matching: metadata, recording: admission.event) else {
            journal.complete(admission, phase: .terminated, replacing: .init(argument: argument, result: .unavailable))
            fatalError(journal.reportMissingCall(admission, source: source).message)
        }
        let result = answer(metadata)
        journal.complete(admission, phase: .returned, replacing: .init(argument: argument, result: .value(())))
        return result
    }

    public func verification(
        matching matcher: Matcher<Metadata>, phase: CallPhase = .admitted
    ) -> BorrowedSpanSyncVerification<Metadata> {
        BorrowedSpanSyncVerification(journal: journal, matcher: matcher, phase: phase)
    }
}
#endif
