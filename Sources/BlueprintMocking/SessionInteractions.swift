/// The session or one explicitly selected mock whose interactions are checked.
public enum SessionInteractionDomain: Equatable, Sendable {
    case session
    case mock(MockID)
}

/// The evidence returned by an interaction-absence assertion at one snapshot.
public struct SessionInteractionResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case noInteractions
        /// A retained admission disproves absence. Earlier admissions may have been pruned.
        case interaction(SessionEvent)
        /// Discarded history prevents proving absence from this snapshot.
        case historyUnavailable
        case foreignMock(MockID)
        /// The lower-bound checkpoint is later than this immutable snapshot.
        case checkpointAfterSnapshot
    }

    public let epoch: SessionEpoch
    public let watermark: UInt64
    public let outcome: Outcome

    public var passed: Bool { outcome == .noInteractions }
}

public extension MockSession {
    /// Checks the current epoch through the watermark captured when this call takes its snapshot.
    func verifyNoInteractions(
        in domain: SessionInteractionDomain,
        since checkpoint: SessionCheckpoint? = nil,
        ignoring endpoints: [SessionCallSelector] = []
    ) throws(SessionCheckpointError) -> SessionInteractionResult {
        try snapshot().verifyNoInteractions(in: domain, since: checkpoint, ignoring: endpoints)
    }
}

public extension SessionSnapshot {
    /// Checks invocation admissions in this snapshot's epoch through its inclusive watermark.
    ///
    /// A checkpoint limits the query to admissions strictly after its watermark. Omit it to
    /// check the whole epoch. Ignore selectors match both mock and endpoint identity.
    func verifyNoInteractions(
        in domain: SessionInteractionDomain,
        since checkpoint: SessionCheckpoint? = nil,
        ignoring endpoints: [SessionCallSelector] = []
    ) throws(SessionCheckpointError) -> SessionInteractionResult {
        if let checkpoint {
            try checkpoint.validate(for: epoch)
        }
        func result(_ outcome: SessionInteractionResult.Outcome) -> SessionInteractionResult {
            SessionInteractionResult(epoch: epoch, watermark: watermark, outcome: outcome)
        }

        let selectedMock: MockID?
        switch domain {
        case .session:
            selectedMock = nil
        case .mock(let mock):
            guard mock.sessionID == sessionID else { return result(.foreignMock(mock)) }
            selectedMock = mock
        }
        if let foreign = endpoints.first(where: { $0.mockID.sessionID != sessionID }) {
            return result(.foreignMock(foreign.mockID))
        }

        // Session ordinals start at one, so zero includes the entire current epoch.
        let lowerBound = checkpoint?.watermark ?? 0
        guard lowerBound <= watermark else { return result(.checkpointAfterSnapshot) }
        let suffix = events[events.firstEventIndex(after: lowerBound)...]
        let evidence = suffix.first { event in
            guard event.phase == .admitted else { return false }
            if let selectedMock, event.mockID != selectedMock { return false }
            return !endpoints.contains { $0.mockID == event.mockID && $0.endpoint == event.endpoint }
        }

        if let evidence { return result(.interaction(evidence)) }
        if let prunedThrough, lowerBound < prunedThrough { return result(.historyUnavailable) }
        return result(.noInteractions)
    }
}
