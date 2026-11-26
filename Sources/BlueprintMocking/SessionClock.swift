/// Chooses how a session measures elapsed time.
public enum SessionClockMode: Sendable {
    /// Use the monotonic system clock.
    case continuous
    /// Start at zero and advance explicitly from the test.
    case manual
}

public enum SessionClockError: Error, Equatable, Sendable {
    case notManual
    case negativeAdvance
}

/// Clock state belongs to the session coordinator. It never calls user code.
enum SessionClockState: Sendable {
    case continuous(origin: ContinuousClock.Instant)
    case manual(elapsed: Duration)

    init(_ mode: SessionClockMode) {
        switch mode {
        case .continuous:
            self = .continuous(origin: ContinuousClock.now)
        case .manual:
            self = .manual(elapsed: .zero)
        }
    }

    var elapsed: Duration {
        switch self {
        case .continuous(let origin):
            origin.duration(to: ContinuousClock.now)
        case .manual(let elapsed):
            elapsed
        }
    }

    func continuousInstant(at elapsed: Duration) -> ContinuousClock.Instant? {
        guard case .continuous(let origin) = self else { return nil }
        return origin.advanced(by: elapsed)
    }

    mutating func advance(by duration: Duration) throws(SessionClockError) {
        guard case .manual(let elapsed) = self else { throw .notManual }
        guard duration >= .zero else { throw .negativeAdvance }
        self = .manual(elapsed: elapsed + duration)
    }
}
