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
}

public enum SessionCheckpointError: Error, Equatable, Sendable {
    /// The checkpoint was created by a different session.
    case foreignSession
    /// A history reset changed the session's current epoch.
    case staleEpoch
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
        guard current.sessionID == checkpoint.sessionID else { throw .foreignSession }
        guard current.epoch == checkpoint.epoch else { throw .staleEpoch }

        let events = current.events
        var lower = events.startIndex
        var upper = events.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].ordinal <= checkpoint.watermark {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return Array(events[lower...])
    }
}
