import BlueprintMocking
import Darwin
import Dispatch
import Foundation

private let latencyCount = 10_000
private let warmupCount = 2_000
private let concurrentWorkers = 8
private let concurrentCount = 100_000
private let retirementCount = 2_000

private struct Heap {
    let blocks: UInt64
    let bytes: UInt64

    init() {
        var stats = malloc_statistics_t()
        // Darwin sums statistics for all malloc zones when the zone is nil.
        malloc_zone_statistics(nil, &stats)
        blocks = UInt64(stats.blocks_in_use)
        bytes = UInt64(stats.size_in_use)
    }

    var record: [String: UInt64] { ["liveBlocks": blocks, "liveBytes": bytes] }
}

private func timeNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return UInt64(usage.ru_maxrss)
}

private func makeScalarEndpoint(in session: MockSession) -> SyncEndpoint<Int, Int> {
    let setup = SyncStubbing<Int, Int>()
    setup.matching(.equal(7)).willReturn(29)
    return SyncEndpoint(
        id: EndpointID("performance.scalar"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in fatalError(issue.message) }, scope: session.makeMock()
    )
}

private func validate(_ session: MockSession, calls: Int) -> [String: Any] {
    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let returns = snapshot.events.filter { $0.phase == .returned }
    let admissionIDs = Set(admissions.map(\.invocationID))
    let returnIDs = Set(returns.map(\.invocationID))
    return [
        "admissions": admissions.count,
        "returns": returns.count,
        "uniqueAdmissions": admissionIDs.count,
        "uniqueReturns": returnIDs.count,
        "identitySetsMatch": admissionIDs == returnIDs,
        "epochMatches": snapshot.events.allSatisfy {
            $0.epoch == snapshot.epoch && $0.invocationID.sessionID == snapshot.sessionID
        },
        "unpruned": snapshot.prunedThrough == nil,
        "active": snapshot.activeInvocationCount,
        "typedReturnedMatches": calls,
    ]
}

private func latency() throws -> [String: Any] {
    // Warm the same path in a separate session to keep measured history empty.
    do {
        let warm = MockSession()
        let endpoint = makeScalarEndpoint(in: warm)
        for _ in 0..<warmupCount { precondition(endpoint.invoke(7) == 29) }
        _ = try warm.finishIfQuiescent()
    }
    let session = MockSession()
    let endpoint = makeScalarEndpoint(in: session)
    var durations: [UInt64] = []
    durations.reserveCapacity(latencyCount)
    let before = Heap()
    let start = timeNanos()
    var checksum = 0
    for _ in 0..<latencyCount {
        let tick = timeNanos()
        let value = endpoint.invoke(7)
        let duration = timeNanos() - tick
        durations.append(duration)
        checksum += value
    }
    let elapsed = timeNanos() - start
    let after = Heap()
    precondition(checksum == latencyCount * 29)
    durations.sort()
    func percentile(_ percent: Int) -> UInt64 {
        durations[(durations.count * percent + 99) / 100 - 1]
    }
    let proof = endpoint.verification(matching: .equal(7), phase: .returned).wasCalled(.exactly(latencyCount))
    precondition(proof.passed)
    let history = validate(session, calls: proof.observed)
    return [
        "mode": "latency",
        "calls": latencyCount,
        "workers": 1,
        "warmupCalls": warmupCount,
        "durationNanos": elapsed,
        "percentilesNanos": ["p50": percentile(50), "p95": percentile(95), "p99": percentile(99)],
        "heapBefore": before.record,
        "heapAfter": after.record,
        "peakResidentBytes": peakResidentBytes(),
        "history": history,
    ]
}

private func admission() -> [String: Any] {
    let session = MockSession()
    let endpoint = makeScalarEndpoint(in: session)
    let ready = DispatchGroup()
    let completed = DispatchGroup()
    let begin = DispatchSemaphore(value: 0)
    for _ in 0..<concurrentWorkers {
        ready.enter()
        completed.enter()
        Thread.detachNewThread {
            ready.leave()
            begin.wait()
            for _ in 0..<(concurrentCount / concurrentWorkers) {
                precondition(endpoint.invoke(7) == 29)
            }
            completed.leave()
        }
    }
    ready.wait()
    let before = Heap()
    let start = timeNanos()
    for _ in 0..<concurrentWorkers { begin.signal() }
    completed.wait()
    let elapsed = timeNanos() - start
    let after = Heap()
    let proof = endpoint.verification(matching: .equal(7), phase: .returned).wasCalled(.exactly(concurrentCount))
    precondition(proof.passed)
    let history = validate(session, calls: proof.observed)
    return [
        "mode": "admission",
        "calls": concurrentCount,
        "workers": concurrentWorkers,
        "durationNanos": elapsed,
        "heapBefore": before.record,
        "heapAfter": after.record,
        "peakResidentBytes": peakResidentBytes(),
        "history": history,
    ]
}

private final class RetainedValue: Sendable {
    let released: @Sendable () -> Void

    init(released: @escaping @Sendable () -> Void) {
        self.released = released
    }

    deinit { released() }
}

private func retirement() throws -> [String: Any] {
    let session = MockSession()
    let setup = SyncStubbing<RetainedValue, Int>()
    setup.matching(.any).willReturn(29)
    let endpoint = SyncEndpoint(
        id: EndpointID("performance.retained-reference"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in fatalError(issue.message) }, scope: session.makeMock()
    )
    let released = StoredProperty(0)
    let before = Heap()
    for _ in 0..<retirementCount {
        precondition(endpoint.invoke(RetainedValue { released.set(released.get() + 1) }) == 29)
    }
    let retained = Heap()
    let releasedBeforeReset = released.get()
    let beforeReset = timeNanos()
    _ = try session.resetHistory()
    let resetDuration = timeNanos() - beforeReset
    let releasedAfterReset = released.get()
    let afterReset = Heap()
    let beforeFinish = timeNanos()
    let finished = try session.finishIfQuiescent()
    let finishDuration = timeNanos() - beforeFinish
    // Reset and the measurements retire the history while its owner remains alive.
    withExtendedLifetime(endpoint) {}
    return [
        "mode": "retirement",
        "calls": retirementCount,
        "workers": 1,
        "releasedBeforeReset": releasedBeforeReset,
        "releasedAfterReset": releasedAfterReset,
        "resetNanos": resetDuration,
        "finishNanos": finishDuration,
        "heapBefore": before.record,
        "heapAfter": retained.record,
        "heapAfterReset": afterReset.record,
        "peakResidentBytes": peakResidentBytes(),
        "activeAfterFinish": finished.activeInvocationCount,
        "eventsAfterFinish": finished.events.count,
        "finished": finished.isFinished,
    ]
}

@main
private struct RuntimePerformanceProbe {
    static func main() throws {
        let sample = switch CommandLine.arguments.dropFirst().first {
        case "latency": try latency()
        case "admission": admission()
        case "retirement": try retirement()
        default: fatalError("Expected latency, admission or retirement")
        }
        let output = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
