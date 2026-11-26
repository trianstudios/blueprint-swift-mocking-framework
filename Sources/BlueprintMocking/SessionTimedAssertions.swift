/// The metadata count and committed history position at a timed observation result.
public struct SessionTimedCountObservation: Equatable, Sendable {
    public let epoch: SessionEpoch
    /// The last included event position. Events at the exclusive cutoff are excluded.
    public let watermark: UInt64
    public let observed: Int
    /// Elapsed session time at the qualifying event, violation, or timed boundary.
    public let elapsed: Duration
}

public enum SessionTimedObservationError: Error, Equatable, Sendable {
    case violated(SessionTimedCountObservation)
    case deadlineExceeded
    case invalidDuration
    case contradictoryCount
    case foreignMock(MockID)
    case sessionFinished
}

public extension MockSession {
    /// Returns the first committed prefix satisfying the count within the timeout.
    ///
    /// The session clock starts the timeout at registration. The initial snapshot
    /// can satisfy the count immediately. Replayed events qualify only if stamped
    /// strictly before the deadline, even when the observer wakes afterward.
    func eventually(
        _ count: CallCount, for selector: SessionCallSelector,
        phase: CallPhase = .admitted, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareTimedCount(count, for: selector, phase: phase, window: .eventually(timeout)).value()
    }

    /// Requires the count to hold at registration and through every metadata event
    /// strictly before the end of the interval. The interval uses the session clock.
    /// Throws if the observation cannot prove its history or the session ends early.
    func until(
        _ count: CallCount, for selector: SessionCallSelector,
        phase: CallPhase = .admitted, for duration: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareTimedCount(count, for: selector, phase: phase, window: .until(duration)).value()
    }

    /// Returns when the count holds for an uninterrupted interval within the timeout.
    /// A violation before the end of a candidate interval restarts the search. A
    /// candidate ending at the overall deadline qualifies. Both durations must be
    /// positive, and the required interval must fit within the timeout.
    func stable(
        _ count: CallCount, for selector: SessionCallSelector,
        phase: CallPhase = .admitted, for duration: Duration, within timeout: Duration
    ) async throws -> SessionTimedCountObservation {
        try await prepareTimedCount(
            count, for: selector, phase: phase, window: .stable(duration, within: timeout)
        ).value()
    }
}

enum TimedCountWindow: Sendable {
    case eventually(Duration)
    case until(Duration)
    case stable(Duration, within: Duration)
}

extension MockSession {
    func prepareTimedCount(
        _ count: CallCount, for selector: SessionCallSelector,
        phase: CallPhase = .admitted, window: TimedCountWindow
    ) throws -> TimedCountWait {
        try Task.checkCancellation()
        guard selector.mockID.sessionID == id else {
            throw SessionTimedObservationError.foreignMock(selector.mockID)
        }
        guard count.isSatisfiable else { throw SessionTimedObservationError.contradictoryCount }

        let timeout: Duration
        switch window {
        case let .eventually(duration), let .until(duration):
            timeout = duration
        case let .stable(duration, within: limit):
            guard duration > .zero, duration <= limit else {
                throw SessionTimedObservationError.invalidDuration
            }
            timeout = limit
        }
        guard timeout > .zero else { throw SessionTimedObservationError.invalidDuration }

        let observation = observeChanges()
        guard observation.initialSnapshot.prunedThrough == nil else {
            observation.cancel()
            throw SessionCheckpointError.historyUnavailable
        }
        return TimedCountWait(
            session: self, observation: observation, count: count, selector: selector, phase: phase,
            deadline: observation.initialElapsed + timeout, window: window
        )
    }
}

/// One registered wait with a single consumer of the notification stream.
struct TimedCountWait: Sendable {
    let session: MockSession
    let observation: SessionObservation
    let count: CallCount
    let selector: SessionCallSelector
    let phase: CallPhase
    let deadline: Duration
    let window: TimedCountWindow

    func value() async throws -> SessionTimedCountObservation {
        var timer: Task<Void, Never>?
        defer {
            timer?.cancel()
            observation.cancel()
        }

        try Task.checkCancellation()
        let initial = observation.initialSnapshot
        let initialCount = initial.events.lazy.filter(matches).count
        try Task.checkCancellation()
        var progress = Progress(observed: initialCount, watermark: initial.watermark)
        if count.accepts(initialCount) {
            switch window {
            case .eventually: return result(progress, at: observation.initialElapsed)
            case .until: break
            case .stable: progress.satisfyingSince = observation.initialElapsed
            }
        } else if case .until = window {
            throw SessionTimedObservationError.violated(result(progress, at: observation.initialElapsed))
        }

        var cursor = observation.checkpoint
        var notifications = observation.notifications.makeAsyncIterator()
        var scheduledDeadline: Duration?
        var streamOpen = true

        while true {
            try Task.checkCancellation()
            let cut = session.timedSnapshot()
            try cursor.validate(for: cut.snapshot.epoch)
            if let pruned = cut.snapshot.prunedThrough, cursor.watermark < pruned {
                throw SessionCheckpointError.historyUnavailable
            }

            let events = cut.snapshot.events
            for event in events[events.firstEventIndex(after: cursor.watermark)...] {
                // The timestamp and ordinal come from the same commit. Evaluate the
                // earlier clock boundary before applying equal-time or later events.
                if let completed = try completion(progress, by: event.elapsed) { return completed }
                progress.watermark = event.ordinal
                guard matches(event) else { continue }
                progress.observed += 1
                let satisfied = count.accepts(progress.observed)
                switch window {
                case .eventually where satisfied:
                    return result(progress, at: event.elapsed)
                case .until where !satisfied:
                    throw SessionTimedObservationError.violated(result(progress, at: event.elapsed))
                case .stable:
                    progress.satisfyingSince = satisfied ? (progress.satisfyingSince ?? event.elapsed) : nil
                default:
                    break
                }
            }
            if let completed = try completion(progress, by: cut.elapsed) { return completed }
            guard !cut.snapshot.isFinished else { throw SessionTimedObservationError.sessionFinished }
            guard streamOpen else { throw CancellationError() }
            cursor = SessionCheckpoint(snapshot: cut.snapshot)

            let nextDeadline = min(progress.satisfyingSince.flatMap(stableEnd) ?? deadline, deadline)
            if scheduledDeadline != nextDeadline {
                timer?.cancel()
                scheduledDeadline = nextDeadline
                if let instant = session.continuousInstant(at: nextDeadline) {
                    timer = Task { [observation] in
                        do {
                            try await ContinuousClock().sleep(until: instant, tolerance: .zero)
                            try Task.checkCancellation()
                            observation.wake()
                        } catch {
                            // The reader canceled the timer or moved to another deadline.
                        }
                    }
                }
            }
            streamOpen = await notifications.next() != nil
        }
    }

    private struct Progress {
        var observed: Int
        var watermark: UInt64
        var satisfyingSince: Duration?
    }

    private func matches(_ event: SessionEvent) -> Bool {
        event.phase == phase && event.mockID == selector.mockID && event.endpoint == selector.endpoint
    }

    private func stableEnd(since start: Duration) -> Duration? {
        guard case let .stable(duration, within: _) = window else { return nil }
        return start + duration
    }

    private func completion(_ progress: Progress, by time: Duration) throws -> SessionTimedCountObservation? {
        try Task.checkCancellation()
        if case .until = window {
            return time >= deadline ? result(progress, at: deadline) : nil
        }
        if let end = progress.satisfyingSince.flatMap(stableEnd), end <= deadline, time >= end {
            return result(progress, at: end)
        }
        if time >= deadline { throw SessionTimedObservationError.deadlineExceeded }
        return nil
    }

    private func result(_ progress: Progress, at time: Duration) -> SessionTimedCountObservation {
        SessionTimedCountObservation(
            epoch: observation.checkpoint.epoch, watermark: progress.watermark,
            observed: progress.observed, elapsed: time
        )
    }
}
