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
    ) throws -> ProjectedStabilityWait<ProjectedFields<String, Result>> {
        try projectedJournal.prepareArgumentStability(
            count, matchingArgument: argument, for: duration, within: timeout
        )
    }
}

public extension ProjectedSyncEndpoint where Result == String {
    /// Proves a stable count of the given returned result projection.
    /// A result remains pending until its terminal event is committed.
    func stable(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareResultStability(count, matchingResult: result, for: duration, within: timeout).value()
    }
}

extension ProjectedSyncEndpoint where Result == String {
    func prepareResultStability(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<ProjectedFields<Argument, String>> {
        try projectedJournal.prepareResultStability(count, matchingResult: result, for: duration, within: timeout)
    }
}

enum TimedProjectionChange: Sendable {
    case pending
    // A nil resolution means a known non-return. Projected values here are nonoptional strings.
    case resolved(String?)
    case unchanged
}

extension ConfiguredJournal {
    func prepareArgumentStability<Result: Sendable>(
        _ count: CallCount, matchingArgument argument: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<Input> where Input == ProjectedFields<String, Result> {
        try prepareProjectionStability(count, matching: argument, for: duration, within: timeout) { change in
            switch change {
            case .admitted:
                return .pending
            case .argument(let input):
                if case .value(let value) = input.argument { return .resolved(value) }
                return .unchanged
            case .completed:
                return .unchanged
            }
        }
    }

    func prepareResultStability<Argument: Sendable>(
        _ count: CallCount, matchingResult result: String, for duration: Duration, within timeout: Duration
    ) throws -> ProjectedStabilityWait<Input> where Input == ProjectedFields<Argument, String> {
        try prepareProjectionStability(count, matching: result, for: duration, within: timeout) { change in
            switch change {
            case .admitted:
                return .pending
            case .completed(.returned, let input):
                if let input, case .value(let value) = input.result { return .resolved(value) }
                return .unchanged
            case .completed(.threw, _), .completed(.terminated, _):
                return .resolved(nil)
            case .completed(.admitted, _), .argument:
                return .unchanged
            }
        }
    }

    private func prepareProjectionStability(
        _ count: CallCount, matching literal: String, for duration: Duration, within timeout: Duration,
        classify: @escaping @Sendable (ProjectionJournalChange<Input>) -> TimedProjectionChange
    ) throws -> ProjectedStabilityWait<Input> {
        try Task.checkCancellation()
        guard count.isSatisfiable else { throw SessionTimedObservationError.contradictoryCount }
        guard duration > .zero, duration <= timeout else { throw SessionTimedObservationError.invalidDuration }
        let session = projectionSession
        let observation = session.observeChanges()
        guard observation.initialSnapshot.prunedThrough == nil else {
            observation.cancel()
            throw SessionCheckpointError.historyUnavailable
        }
        return ProjectedStabilityWait(
            session: session, observation: observation, read: { self.timedProjectionCut() },
            classify: classify, literal: literal, count: count, duration: duration,
            deadline: observation.initialElapsed + timeout
        )
    }
}

struct ProjectedStabilityWait<History: Sendable>: Sendable {
    let session: MockSession
    let observation: SessionObservation
    let read: @Sendable () -> ProjectionJournalCut<History>
    let classify: @Sendable (ProjectionJournalChange<History>) -> TimedProjectionChange
    let literal: String
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
            progress.apply(event, as: classify(event.change), matching: literal)
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
                progress.apply(event, as: classify(event.change), matching: literal)
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

    private func validate(_ cut: ProjectionJournalCut<History>,
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

        mutating func apply(
            _ event: ProjectionJournalEvent<History>, as change: TimedProjectionChange, matching literal: String
        ) {
            watermark = event.ordinal
            switch change {
            case .pending:
                pending.insert(event.invocationID)
            case .resolved(let value):
                if pending.remove(event.invocationID) != nil, value == literal { observed += 1 }
            case .unchanged:
                break
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
