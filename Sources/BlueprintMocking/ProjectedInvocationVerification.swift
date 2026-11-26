/// One matched projected value and the identity of the invocation that produced it.
public struct ProjectedInvocationCapture<Value: Sendable>: Sendable {
    public let id: UInt64
    public let sessionInvocationID: SessionInvocationID
    public let value: Value
}

/// The outcome of verifying one projected field at a fixed endpoint watermark.
public struct ProjectedVerificationResult<Value: Sendable>: Sendable {
    public enum Status: Sendable, Equatable {
        case matched
        case countMismatch
        case contradictoryCount
        case incompleteHistory
    }

    public let status: Status
    public let epoch: SessionEpoch
    public let watermark: UInt64
    /// The number of known matches. A contradictory count skips matching and returns nil.
    public let observed: Int?
    /// Captures are published only for a successful, complete match.
    public let captures: [ProjectedInvocationCapture<Value>]
    public let pendingInvocationIDs: [SessionInvocationID]
    public let unavailableInvocationIDs: [SessionInvocationID]

    public var passed: Bool { status == .matched }
}

public extension ProjectedInvocationHistory {
    /// Verifies an argument projection against the immutable history records in admission order.
    ///
    /// Supply a value snapshot when capture-time values matter. A Sendable reference can
    /// still change after projection. The matcher runs over stored projections outside runtime locks.
    func verify(
        _ count: CallCount,
        matchingArgument matcher: Matcher<Argument>,
        phase: CallPhase = .admitted
    ) -> ProjectedVerificationResult<Argument> {
        verifyProjected(count, matcher: matcher, phase: phase) { $0.argument }
    }

    /// Verifies a result projection. By default this considers returned calls only.
    ///
    /// Use .admitted to consider all admitted calls, including pending results and
    /// terminal calls with unavailable results. Incomplete fields preclude a complete capture set.
    func verify(
        _ count: CallCount,
        matchingResult matcher: Matcher<Result>,
        phase: CallPhase = .returned
    ) -> ProjectedVerificationResult<Result> {
        verifyProjected(count, matcher: matcher, phase: phase) { $0.result }
    }

    private func verifyProjected<Value: Sendable>(
        _ count: CallCount,
        matcher: Matcher<Value>,
        phase: CallPhase,
        field: (ProjectedInvocation<Argument, Result>) -> ProjectedValue<Value>
    ) -> ProjectedVerificationResult<Value> {
        guard count.isSatisfiable else {
            return ProjectedVerificationResult(
                status: .contradictoryCount, epoch: epoch, watermark: watermark,
                observed: nil, captures: [], pendingInvocationIDs: [], unavailableInvocationIDs: [])
        }

        var matches: [ProjectedInvocationCapture<Value>] = []
        var pending: [SessionInvocationID] = []
        var unavailable: [SessionInvocationID] = []
        for call in calls where phase == .admitted || call.phase == phase {
            switch field(call) {
            case .value(let value):
                if matcher.matches(value) {
                    matches.append(ProjectedInvocationCapture(
                        id: call.id, sessionInvocationID: call.sessionInvocationID, value: value))
                }
            case .pending:
                pending.append(call.sessionInvocationID)
            case .unavailable:
                unavailable.append(call.sessionInvocationID)
            }
        }

        let status: ProjectedVerificationResult<Value>.Status
        if !pending.isEmpty || !unavailable.isEmpty {
            status = .incompleteHistory
        } else {
            status = count.accepts(matches.count) ? .matched : .countMismatch
        }
        return ProjectedVerificationResult(
            status: status, epoch: epoch, watermark: watermark, observed: matches.count,
            captures: status == .matched ? matches : [], pendingInvocationIDs: pending,
            unavailableInvocationIDs: unavailable)
    }
}
