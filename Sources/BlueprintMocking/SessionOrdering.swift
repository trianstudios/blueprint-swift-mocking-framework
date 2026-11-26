/// Identifies one endpoint without inspecting or retaining its arguments.
public struct SessionCallSelector: Equatable, Sendable {
    public let mockID: MockID
    public let endpoint: EndpointID

    public init(mockID: MockID, endpoint: EndpointID) {
        self.mockID = mockID
        self.endpoint = endpoint
    }

    fileprivate func matches(_ event: SessionEvent) -> Bool {
        event.mockID == mockID && event.endpoint == endpoint
    }
}

/// The relationship required between the ordered events.
public enum SessionOrderMode: Sendable {
    /// Other events in the selected phase may appear between matches.
    case relative
    /// Matches must be consecutive among all events in the selected phase.
    case strict
}

public enum SessionOrderResult: Equatable, Sendable {
    case matched([SessionEvent])
    case notMatched
    /// No match is provable in the retained events, and earlier events were discarded.
    case historyUnavailable
    /// The selector belongs to another session and cannot be ordered in this snapshot.
    case foreignMock(MockID)
}

public extension SessionSnapshot {
    /// Finds the earliest provable match in the snapshot's retained events.
    ///
    /// Every selector uses the same phase. An empty selection succeeds with no matched events.
    /// This operation reads metadata only and leaves the history untouched.
    func matchOrder(
        _ selectors: [SessionCallSelector],
        mode: SessionOrderMode,
        phase: CallPhase = .admitted
    ) -> SessionOrderResult {
        if let foreign = selectors.first(where: { $0.mockID.sessionID != sessionID }) {
            return .foreignMock(foreign.mockID)
        }
        guard !selectors.isEmpty else { return .matched([]) }

        let miss: SessionOrderResult = prunedThrough == nil ? .notMatched : .historyUnavailable
        let phaseEvents = events.filter { $0.phase == phase }
        guard selectors.count <= phaseEvents.count else { return miss }
        let matched = switch mode {
        case .relative: matchRelativeOrder(selectors, in: phaseEvents)
        case .strict: matchStrictOrder(selectors, in: phaseEvents)
        }
        return matched.map(SessionOrderResult.matched) ?? miss
    }
}

private func matchRelativeOrder(
    _ selectors: [SessionCallSelector], in events: [SessionEvent]
) -> [SessionEvent]? {
    var matched: [SessionEvent] = []
    matched.reserveCapacity(selectors.count)
    for event in events where selectors[matched.count].matches(event) {
        matched.append(event)
        if matched.count == selectors.count { return matched }
    }
    return nil
}

private func matchStrictOrder(
    _ selectors: [SessionCallSelector], in events: [SessionEvent]
) -> [SessionEvent]? {
    // Record reusable prefixes so a mismatch preserves any overlapping candidate
    // without scanning the same history again (Knuth–Morris–Pratt search).
    var prefixes = [Int](repeating: 0, count: selectors.count)
    for index in selectors.indices.dropFirst() {
        var prefixLength = prefixes[index - 1]
        while prefixLength > 0 && selectors[index] != selectors[prefixLength] {
            prefixLength = prefixes[prefixLength - 1]
        }
        if selectors[index] == selectors[prefixLength] { prefixLength += 1 }
        prefixes[index] = prefixLength
    }

    var matchedCount = 0
    for (index, event) in events.enumerated() {
        while matchedCount > 0 && !selectors[matchedCount].matches(event) {
            matchedCount = prefixes[matchedCount - 1]
        }
        if selectors[matchedCount].matches(event) { matchedCount += 1 }
        if matchedCount == selectors.count {
            let start = index + 1 - matchedCount
            return Array(events[start...index])
        }
    }
    return nil
}
