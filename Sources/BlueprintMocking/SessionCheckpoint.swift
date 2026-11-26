/// An immutable position in a session's event history.
public struct SessionCheckpoint: Sendable, Equatable {
    public let sessionID: SessionID
    public let epoch: SessionEpoch
    public let watermark: UInt64

    fileprivate init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionID
        epoch = snapshot.epoch
        watermark = snapshot.watermark
    }

    func validate(for currentEpoch: SessionEpoch) throws(SessionCheckpointError) {
        guard currentEpoch.sessionID == sessionID else { throw .foreignSession }
        guard currentEpoch == epoch else { throw .staleEpoch }
    }
}

public enum SessionCheckpointError: Error, Equatable, Sendable {
    /// The checkpoint was created by a different session.
    case foreignSession
    /// A history reset changed the session's current epoch.
    case staleEpoch
    /// This checkpoint precedes events that were discarded from the current epoch.
    case historyUnavailable
    /// A finished session's retained events cannot be changed.
    case finishedSession
}

public extension MockSession {
    /// Captures the current epoch and the latest included event ordinal in one snapshot.
    func checkpoint() -> SessionCheckpoint {
        SessionCheckpoint(snapshot: snapshot())
    }

    /// Returns events ordered by ordinal after a checkpoint in the current epoch.
    ///
    /// A call admitted before the checkpoint can have a later event for its completion.
    func events(since checkpoint: SessionCheckpoint) throws(SessionCheckpointError) -> [SessionEvent] {
        let current = snapshot()
        try checkpoint.validate(for: current.epoch)
        if let prunedThrough = current.prunedThrough, checkpoint.watermark < prunedThrough {
            throw .historyUnavailable
        }

        let events = current.events
        return Array(events[events.firstEventIndex(after: checkpoint.watermark)...])
    }

    /// Discards current-epoch session metadata at or before the checkpoint.
    ///
    /// This does not clear endpoint histories or change the admission epoch. Repeating
    /// a discard through an earlier watermark has no effect.
    func discardEvents(through checkpoint: SessionCheckpoint) throws(SessionCheckpointError) {
        _ = try withLock { (state: inout State) throws(SessionCheckpointError) in
            try state.discardEvents(through: checkpoint)
        }
    }
}

extension Array where Element == SessionEvent {
    /// First event strictly after the ordinal in this ordered epoch, or endIndex.
    func firstEventIndex(after ordinal: UInt64) -> Index {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self[middle].ordinal <= ordinal {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
