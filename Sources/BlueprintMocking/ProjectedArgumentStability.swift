/// The projected timeline contained an unsettled interval that prevents a proof.
public enum ProjectedTimedObservationError: Error, Equatable, Sendable {
    case incompleteHistory
}

public extension ProjectedSyncEndpoint where Argument == String {
    /// Proves a count of the given projected string for a continuous session-clock interval.
    /// Admission makes the field pending until publication. A pending field breaks the
    /// candidate interval even when a later publication shows it did not match.
    func stable(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareArgumentStability(count, matchingArgument: argument, for: duration, within: timeout).value()
    }
}

extension ProjectedSyncEndpoint where Argument == String {
    func prepareArgumentStability(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedArgumentStabilityWait<Result> {
        try projectedJournal.prepareArgumentStability(
            count, matchingArgument: argument, for: duration, within: timeout
        )
    }
}

extension ConfiguredJournal {
    func prepareArgumentStability<Result: Sendable>(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedArgumentStabilityWait<Result> where Input == ProjectedFields<String, Result> {
        try Task.checkCancellation()
        guard count.isSatisfiable else { throw SessionTimedObservationError.contradictoryCount }
        guard duration > .zero, duration <= timeout else { throw SessionTimedObservationError.invalidDuration }
        let session = projectionSession
        let observation = session.observeChanges()
        guard observation.initialSnapshot.prunedThrough == nil else {
            observation.cancel()
            throw SessionCheckpointError.historyUnavailable
        }
        return ProjectedArgumentStabilityWait(
            session: session, observation: observation, read: { self.timedProjectionCut() },
            argument: argument, count: count, duration: duration, deadline: observation.initialElapsed + timeout
        )
    }
}

struct ProjectedArgumentStabilityWait<Result: Sendable>: Sendable {
    let session: MockSession
    let observation: SessionObservation
    let read: @Sendable () -> ProjectionJournalCut<ProjectedFields<String, Result>>
    let argument: String
    let count: CallCount
    let duration: Duration
    let deadline: Duration

    func value() async throws -> SessionTimedCountObservation {
        var timer: Task<Void, Never>?
        defer {
            timer?.cancel()
            observation.cancel()
        }

        try Task.checkCancellation()
        var cursor = observation.checkpoint
        var cut = read()
        try validate(cut, after: cursor)

        var progress = Progress(watermark: cursor.watermark)
        for event in cut.events.prefix(while: { $0.ordinal <= cursor.watermark }) {
            progress.apply(event, matching: argument)
        }
        progress.watermark = cursor.watermark
        progress.sawIncomplete = !progress.pending.isEmpty
        if progress.pending.isEmpty, count.accepts(progress.observed) {
            progress.satisfyingSince = observation.initialElapsed
        }

        var notifications = observation.notifications.makeAsyncIterator()
        var scheduledDeadline: Duration?
        var streamOpen = true
        while true {
            try Task.checkCancellation()
            try validate(cut, after: cursor)
            let start = eventOffset(in: cut.events, after: cursor.watermark)
            for event in cut.events[start...] {
                // The boundary is exclusive, even if an event has its exact timestamp.
                if let finished = try completion(progress, by: event.elapsed) { return finished }
                progress.apply(event, matching: argument)
                progress.sawIncomplete = progress.sawIncomplete || !progress.pending.isEmpty
                let satisfies = progress.pending.isEmpty && count.accepts(progress.observed)
                progress.satisfyingSince = satisfies ? (progress.satisfyingSince ?? event.elapsed) : nil
            }
            if let finished = try completion(progress, by: cut.elapsed) { return finished }
            guard !cut.snapshot.isFinished else { throw SessionTimedObservationError.sessionFinished }
            guard streamOpen else { throw CancellationError() }
            cursor = SessionCheckpoint(snapshot: cut.snapshot)

            let boundary = min(progress.satisfyingSince.map { $0 + duration } ?? deadline, deadline)
            if scheduledDeadline != boundary {
                timer?.cancel()
                scheduledDeadline = boundary
                if let instant = session.continuousInstant(at: boundary) {
                    timer = Task { [observation] in
                        do {
                            try await ContinuousClock().sleep(until: instant, tolerance: .zero)
                            try Task.checkCancellation()
                            observation.wake()
                        } catch {
                            // The reader either moved to another candidate or canceled.
                        }
                    }
                }
            }
            streamOpen = await notifications.next() != nil
            cut = read()
        }
    }

    private func validate(_ cut: ProjectionJournalCut<ProjectedFields<String, Result>>,
                          after cursor: SessionCheckpoint) throws(SessionCheckpointError) {
        try cursor.validate(for: cut.snapshot.epoch)
        if let pruned = cut.snapshot.prunedThrough, cursor.watermark < pruned {
            throw .historyUnavailable
        }
    }

    private struct Progress {
        var observed = 0
        var pending: Set<SessionInvocationID> = []
        var sawIncomplete = false
        var satisfyingSince: Duration?
        var watermark: UInt64

        mutating func apply(_ event: ProjectionJournalEvent<ProjectedFields<String, Result>>, matching argument: String) {
            watermark = event.ordinal
            if let input = event.publication {
                if case .value(let value) = input.argument, pending.remove(event.invocationID) != nil {
                    if value == argument { observed += 1 }
                }
            } else {
                pending.insert(event.invocationID)
            }
        }
    }

    private func completion(_ progress: Progress, by time: Duration) throws -> SessionTimedCountObservation? {
        try Task.checkCancellation()
        if let start = progress.satisfyingSince {
            let end = start + duration
            if end <= deadline, time >= end {
                return SessionTimedCountObservation(
                    epoch: observation.checkpoint.epoch, watermark: progress.watermark,
                    observed: progress.observed, elapsed: end
                )
            }
        }
        if time >= deadline {
            if progress.sawIncomplete { throw ProjectedTimedObservationError.incompleteHistory }
            throw SessionTimedObservationError.deadlineExceeded
        }
        return nil
    }
}

private func eventOffset<Input: Sendable>(
    in events: [ProjectionJournalEvent<Input>], after ordinal: UInt64
) -> Int {
    var lower = events.startIndex
    var upper = events.endIndex
    while lower < upper {
        let index = lower + (upper - lower) / 2
        if events[index].ordinal <= ordinal {
            lower = index + 1
        } else {
            upper = index
        }
    }
    return lower
}
