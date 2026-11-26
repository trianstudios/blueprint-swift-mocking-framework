/// A checked Sendable async-throwing endpoint whose history stores projected fields.
/// Matchers and answers receive the original input during the call.
public final class ProjectedAsyncThrowingEndpoint<
    Input: Sendable, Output: Sendable, Failure: Error, Argument: Sendable, Result: Sendable
>: Sendable {
    private typealias History = ProjectedFields<Argument, Result>
    private let dispatch: AsyncThrowingDispatch<Input, Output, Failure, History>
    private let projection: InvocationProjection<Input, Output, Argument, Result>

    public init(
        id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
        projection: InvocationProjection<Input, Output, Argument, Result>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock(),
        failureMapping: (@Sendable (MockIssue) -> Failure)? = nil
    ) {
        dispatch = AsyncThrowingDispatch(id: id, configuration: configuration, failureReporter: failureReporter,
                                         scope: scope, failureMapping: failureMapping,
                                         tracksProjectionTimeline: .strings(argument: Argument.self, result: Result.self))
        self.projection = projection
    }

    /// Replaces the plan for later admissions while in-flight calls retain their admitted revision.
    @discardableResult
    public func replaceConfiguration(_ configuration: AsyncThrowingConfiguration<Input, Output, Failure>) -> RuleRevision {
        dispatch.replaceConfiguration(configuration)
    }

    public func invoke(_ input: Input, source: SourceLocation = SourceLocation()) async throws(Failure) -> Output {
        try await dispatch.invoke(
            input, recording: History(argument: .pending, result: .pending), source: source,
            argumentProjection: { [projection] input in
                History(argument: .value(projection.argument(input)), result: .pending)
            },
            completionProjection: { [projection] admitted, output in
                let result: ProjectedValue<Result> = output.map { .value(projection.result($0)) } ?? .unavailable
                return History(argument: admitted.argument, result: result)
            }
        )
    }

    /// Claims matching projected arguments and returns the selected records on commit.
    public func consume(
        _ selection: SessionConsumptionSelection, matchingArgument matcher: Matcher<Argument>,
        phase: CallPhase = .admitted, in scope: SessionConsumptionScope
    ) throws(ProjectedConsumptionError) -> ProjectedSessionConsumption<Argument, Result> {
        try dispatch.consumeProjected(selection, matchingArgument: matcher, phase: phase, in: scope)
    }

    public func projectedHistory() -> ProjectedInvocationHistory<Argument, Result> {
        ProjectedInvocationHistory(dispatch.snapshot())
    }
}

public extension ProjectedAsyncThrowingEndpoint where Failure == any Error {
    /// Uses a reported `UnexpectedInvocationError` when an ordinary throwing invocation cannot be answered.
    convenience init(
        id: EndpointID, configuration: AsyncThrowingConfiguration<Input, Output, Failure>,
        projection: InvocationProjection<Input, Output, Argument, Result>,
        failureReporter: FailureReporter, scope: MockScope = MockSession().makeMock()
    ) {
        self.init(id: id, configuration: configuration, projection: projection,
                  failureReporter: failureReporter, scope: scope,
                  failureMapping: { UnexpectedInvocationError(issue: $0) })
    }
}

public extension ProjectedAsyncThrowingEndpoint where Argument == String {
    /// Proves a count of the given projected string for a continuous session-clock interval.
    /// Pending argument projections interrupt the interval.
    func stable(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareArgumentStability(count, matchingArgument: argument, for: duration, within: timeout).value()
    }
}

extension ProjectedAsyncThrowingEndpoint where Argument == String {
    func prepareArgumentStability(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<ProjectedFields<String, Result>> {
        try dispatch.prepareArgumentStability(count, matchingArgument: argument, for: duration, within: timeout)
    }
}

public extension ProjectedAsyncThrowingEndpoint where Result == String {
    /// Proves a stable count of returned result projections. A thrown call settles
    /// its pending result as a known non-return.
    func stable(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareResultStability(count, matchingResult: result, for: duration, within: timeout).value()
    }
}

extension ProjectedAsyncThrowingEndpoint where Result == String {
    func prepareResultStability(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<ProjectedFields<Argument, String>> {
        try dispatch.prepareResultStability(count, matchingResult: result, for: duration, within: timeout)
    }
}
