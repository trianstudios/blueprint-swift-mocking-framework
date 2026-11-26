/// A committed consumption claim and the projected records selected in the same transaction.
public struct ProjectedSessionConsumption<Argument: Sendable, Result: Sendable>: Sendable {
    public let claim: SessionConsumption
    public let captures: [ProjectedInvocation<Argument, Result>]
}

public enum ProjectedConsumptionError: Error, Equatable, Sendable {
    case claim(SessionConsumptionError)
    case pendingProjection(SessionInvocationID)
    case unavailableProjection(SessionInvocationID)
}

public extension ProjectedSyncEndpoint {
    /// Claims unconsumed invocations whose retained argument projection matches.
    ///
    /// The matcher runs outside synchronization against a fixed history prefix.
    /// The successful claim publishes the associated typed captures as its result.
    /// An earlier pending or unavailable projection prevents proving a complete selection.
    func consume(
        _ selection: SessionConsumptionSelection, matchingArgument matcher: Matcher<Argument>,
        phase: CallPhase = .admitted, in scope: SessionConsumptionScope
    ) throws(ProjectedConsumptionError) -> ProjectedSessionConsumption<Argument, Result> {
        try projectedJournal.consumeProjected(selection, matchingArgument: matcher, phase: phase, in: scope)
    }
}

extension ConfiguredJournal {
    func consumeProjected<Argument: Sendable, Result: Sendable>(
        _ selection: SessionConsumptionSelection, matchingArgument matcher: Matcher<Argument>,
        phase: CallPhase, in scope: SessionConsumptionScope
    ) throws(ProjectedConsumptionError) -> ProjectedSessionConsumption<Argument, Result>
        where Input == ProjectedFields<Argument, Result> {
        let limit: Int?
        switch selection {
        case .all:
            limit = nil
        case .earliest(let count):
            guard count >= 0 else { throw .claim(.invalidSelection) }
            limit = count
        }

        let prepared: (journal: JournalSnapshot<Input>, claims: SessionConsumptionClaims, watermark: UInt64)
        do {
            prepared = try captureForConsumption(in: scope)
        } catch {
            throw .claim(error)
        }
        let history = ProjectedInvocationHistory(prepared.journal)
        var captures: [ProjectedInvocation<Argument, Result>] = []
        for call in history.calls {
            if let limit, captures.count == limit { break }
            guard phase == .admitted || call.phase == phase else { continue }
            guard !prepared.claims.invocationIDs.contains(call.sessionInvocationID) else { continue }

            switch call.argument {
            case .pending:
                throw .pendingProjection(call.sessionInvocationID)
            case .unavailable:
                throw .unavailableProjection(call.sessionInvocationID)
            case .value(let value):
                if matcher.matches(value) { captures.append(call) }
            }
        }
        if let limit, captures.count < limit {
            throw .claim(.insufficientMatches(requested: limit, available: captures.count))
        }

        let claim = SessionConsumption(
            scope: scope, invocationIDs: captures.map(\.sessionInvocationID), watermark: prepared.watermark
        )
        do {
            try commitPreparedConsumption(PreparedSessionConsumption(
                result: claim, scopeRevision: prepared.claims.revision
            ))
        } catch {
            throw .claim(error)
        }
        return ProjectedSessionConsumption(claim: claim, captures: captures)
    }
}
