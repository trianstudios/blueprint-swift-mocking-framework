/// A named verification scope that belongs to one session epoch.
public struct SessionConsumptionScope: Hashable, Sendable {
    public let name: String
    public let epoch: SessionEpoch

    public var sessionID: SessionID { epoch.sessionID }

    func validate(for currentEpoch: SessionEpoch) throws(SessionConsumptionError) {
        guard currentEpoch.sessionID == sessionID else { throw .foreignSession }
        guard currentEpoch == epoch else { throw .staleEpoch }
    }
}

public enum SessionConsumptionSelection: Sendable {
    /// Claim every unclaimed matching admission through the selected snapshot.
    case all
    /// Claim exactly this many unclaimed matching admissions in admission order.
    case earliest(Int)
}

/// Invocation IDs claimed together from one snapshot, in admission order.
public struct SessionConsumption: Equatable, Sendable {
    public let scope: SessionConsumptionScope
    public let invocationIDs: [SessionInvocationID]
    public let watermark: UInt64
}

public enum SessionConsumptionError: Error, Equatable, Sendable {
    case foreignSession
    case staleEpoch
    case foreignMock(MockID)
    case historyUnavailable
    case invalidSelection
    case insufficientMatches(requested: Int, available: Int)
    /// Another claim changed the named scope before this selection could commit.
    case conflict
}

struct SessionConsumptionClaims: Sendable {
    var revision: UInt64 = 0
    var invocationIDs: Set<SessionInvocationID> = []
}

struct PreparedSessionConsumption: Sendable {
    let result: SessionConsumption
    let scopeRevision: UInt64

    init(result: SessionConsumption, scopeRevision: UInt64) {
        self.result = result
        self.scopeRevision = scopeRevision
    }
}

public extension MockSession {
    /// A name identifies the same claim set whenever used in the same epoch.
    func consumptionScope(named name: String) -> SessionConsumptionScope {
        withLock { SessionConsumptionScope(name: name, epoch: $0.epoch) }
    }

    /// Claims matching invocation IDs from complete, retained session metadata.
    /// A conflict leaves every selected ID untouched by this operation. Retry by
    /// making a new selection. New calls after the result's watermark stay unclaimed.
    @discardableResult
    func consume(
        _ selection: SessionConsumptionSelection, for selector: SessionCallSelector,
        in scope: SessionConsumptionScope
    ) throws(SessionConsumptionError) -> SessionConsumption {
        try commitConsumption(prepareConsumption(selection, for: selector, in: scope))
    }
}

extension MockSession {
    func prepareConsumption(
        _ selection: SessionConsumptionSelection, for selector: SessionCallSelector,
        in scope: SessionConsumptionScope
    ) throws(SessionConsumptionError) -> PreparedSessionConsumption {
        let (snapshot, claims) = try withLock { (state: inout State) throws(SessionConsumptionError) in
            try state.captureConsumption(in: scope)
        }
        guard selector.mockID.sessionID == id else { throw .foreignMock(selector.mockID) }
        if case .earliest(let count) = selection, count < 0 { throw .invalidSelection }
        guard snapshot.prunedThrough == nil else { throw .historyUnavailable }

        let matches = snapshot.events.lazy.filter {
            $0.phase == .admitted && $0.mockID == selector.mockID && $0.endpoint == selector.endpoint &&
                !claims.invocationIDs.contains($0.invocationID)
        }.map(\.invocationID)
        let ids: [SessionInvocationID]
        switch selection {
        case .all:
            ids = Array(matches)
        case .earliest(let count):
            ids = Array(matches.prefix(count))
            guard ids.count == count else {
                throw .insufficientMatches(requested: count, available: ids.count)
            }
        }
        let result = SessionConsumption(scope: scope, invocationIDs: ids, watermark: snapshot.watermark)
        return PreparedSessionConsumption(result: result, scopeRevision: claims.revision)
    }

    @discardableResult
    func commitConsumption(_ prepared: PreparedSessionConsumption)
        throws(SessionConsumptionError) -> SessionConsumption {
        try withLock { (state: inout State) throws(SessionConsumptionError) in
            try state.commitConsumption(prepared)
        }
        return prepared.result
    }

    func consumptionSnapshot(in scope: SessionConsumptionScope) throws(SessionConsumptionError)
        -> (snapshot: SessionSnapshot, consumedInvocationIDs: Set<SessionInvocationID>) {
        let (snapshot, claims) = try withLock { (state: inout State) throws(SessionConsumptionError) in
            try state.captureConsumption(in: scope)
        }
        return (snapshot, claims.invocationIDs)
    }
}
