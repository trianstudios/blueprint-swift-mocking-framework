/// The first retained history prefix that satisfied a timed metadata count.
public struct SessionCountObservation: Sendable, Equatable {
    public let epoch: SessionEpoch
    public let watermark: UInt64
    public let observed: Int
}

public enum SessionCountObservationError: Error, Equatable, Sendable {
    case deadlineExceeded
    case contradictoryCount
    case foreignMock(MockID)
    case sessionFinished
}

public extension MockSession {
    /// Reads every retained prefix after registration until the count is satisfied.
    ///
    /// The deadline is exclusive. A satisfying prefix must be observed before it.
    /// The result proves that prefix only, even if additional calls have since arrived.
    /// The query uses metadata and fails if its history has been discarded or reset.
    func eventually<C: Clock>(
        _ count: CallCount, for selector: SessionCallSelector,
        phase: CallPhase = .admitted, until deadline: C.Instant, clock: C
    ) async throws -> SessionCountObservation {
        try Task.checkCancellation()
        guard selector.mockID.sessionID == id else {
            throw SessionCountObservationError.foreignMock(selector.mockID)
        }
        guard count.isSatisfiable else { throw SessionCountObservationError.contradictoryCount }
        guard clock.now < deadline else { throw SessionCountObservationError.deadlineExceeded }

        let observation = observeChanges()
        defer { observation.cancel() }
        let initial = observation.initialSnapshot
        guard initial.prunedThrough == nil else { throw SessionCheckpointError.historyUnavailable }

        let matches: @Sendable (SessionEvent) -> Bool = { event in
            event.phase == phase && event.mockID == selector.mockID && event.endpoint == selector.endpoint
        }
        let initialCount = initial.events.lazy.filter(matches).count
        try Task.checkCancellation()
        guard clock.now < deadline else { throw SessionCountObservationError.deadlineExceeded }
        if count.accepts(initialCount) {
            return SessionCountObservation(epoch: initial.epoch, watermark: initial.watermark, observed: initialCount)
        }
        guard !initial.isFinished else { throw SessionCountObservationError.sessionFinished }

        do {
            let result = try await withThrowingTaskGroup(of: SessionCountObservation.self) { group in
                group.addTask {
                    var cursor = observation.checkpoint
                    var observed = initialCount
                    for await _ in observation.notifications {
                        try Task.checkCancellation()
                        guard clock.now < deadline else { throw SessionCountObservationError.deadlineExceeded }
                        let replay = try self.replay(since: cursor)
                        for event in replay.events where matches(event) {
                            observed += 1
                            if count.accepts(observed) {
                                guard clock.now < deadline else { throw SessionCountObservationError.deadlineExceeded }
                                return SessionCountObservation(epoch: event.epoch, watermark: event.ordinal,
                                                               observed: observed)
                            }
                        }
                        cursor = replay.checkpoint
                    }
                    try Task.checkCancellation()
                    try cursor.validate(for: self.snapshot().epoch)
                    throw SessionCountObservationError.sessionFinished
                }
                group.addTask {
                    try await clock.sleep(until: deadline, tolerance: .zero)
                    throw SessionCountObservationError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
