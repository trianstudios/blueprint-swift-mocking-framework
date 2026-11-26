/// Selects which terminal outcome qualifies as a completion.
public enum SessionCompletionPhase: Sendable, Equatable {
    case any
    case returned
    case threw
    case terminated

    fileprivate func includes(_ phase: CallPhase) -> Bool {
        switch self {
        case .any: phase == .returned || phase == .threw || phase == .terminated
        case .returned: phase == .returned
        case .threw: phase == .threw
        case .terminated: phase == .terminated
        }
    }
}

public extension SessionSnapshot {
    /// Finds a retained completion followed by the admission of a distinct invocation.
    ///
    /// Returns the earliest qualifying completion and its earliest later matching
    /// admission, in that order. Both events appear in this snapshot's epoch at or
    /// before its watermark. A pruned prefix can make an unsuccessful search inconclusive.
    func matchCompletion(
        of completed: SessionCallSelector,
        beforeStartOf started: SessionCallSelector,
        phase: SessionCompletionPhase = .any
    ) -> SessionOrderResult {
        if completed.mockID.sessionID != sessionID { return .foreignMock(completed.mockID) }
        if started.mockID.sessionID != sessionID { return .foreignMock(started.mockID) }

        var firstCompletion: SessionEvent?
        for event in events {
            if let completion = firstCompletion {
                if event.phase == .admitted, event.invocationID != completion.invocationID,
                   event.mockID == started.mockID, event.endpoint == started.endpoint {
                    return .matched([completion, event])
                }
            } else if phase.includes(event.phase),
                      event.mockID == completed.mockID, event.endpoint == completed.endpoint {
                firstCompletion = event
            }
        }
        return prunedThrough == nil ? .notMatched : .historyUnavailable
    }
}
