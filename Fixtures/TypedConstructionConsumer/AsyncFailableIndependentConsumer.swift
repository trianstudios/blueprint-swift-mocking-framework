import AsyncFailableConstructorDomain
import BlueprintMocking
import Foundation

private typealias Mock = AsyncFailableConstructionDirectoryMock

private let reporter = FailureReporter { issue in
    let line = "Async failable constructor issue: \(issue.message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

private actor SetupGate {
    private var releaseSetup: CheckedContinuation<Void, Never>?
    private var notifyObserver: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            precondition(releaseSetup == nil)
            releaseSetup = continuation
            notifyObserver?.resume()
            notifyObserver = nil
        }
    }

    func waitForSuspension() async {
        if releaseSetup != nil { return }
        await withCheckedContinuation { notifyObserver = $0 }
    }

    func release() {
        let next = releaseSetup!
        releaseSetup = nil
        next.resume()
    }
}

@main struct AsyncFailableIndependentConsumer {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "unscoped" {
            _ = await createAsyncFailableDirectory(Mock.self, seed: -1)
            preconditionFailure("An unbound attempt was mistaken for a configured nil")
        }
        for cancelling in [false, true] {
            try await verify(seed: -21, cancelling: cancelling)
            try await verify(seed: 21, cancelling: cancelling)
        }
        print("PASS: GEN026 async failable construction records completed nil and attached success despite cancellation")
    }

    private static func verify(seed: Int, cancelling: Bool) async throws {
        let session = MockSession()
        let original = session.snapshot().epoch
        let gate = SetupGate()
        let scope = Mock.makeConstructionScope(failureReporter: reporter, session: session) { seed, stubs in
            await gate.suspend()
            precondition(Task.isCancelled == cancelling)
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
            return seed < 0 ? .returnNil : .initialize
        }
        let prior = session.makeMock().id
        let task = Task.detached {
            await scope.withValue { await createAsyncFailableDirectory(Mock.self, seed: seed) }
        }
        await gate.waitForSuspension()

        let admitted = session.snapshot()
        precondition(admitted.events.map(\.phase) == [.admitted])
        precondition(admitted.cancellationRequests.isEmpty && admitted.activeInvocationCount == 1)
        let attempt = admitted.events[0]
        precondition(attempt.constructedMockID == nil)
        precondition(attempt.endpoint.rawValue.contains("|init?(seed:Swift.Int) async->Self?|"))
        if cancelling {
            _ = try session.resetHistory(.detachActive)
            task.cancel()
            let current = session.snapshot()
            precondition(current.epoch != original && current.events.isEmpty && current.cancellationRequests.isEmpty)
        }
        let suspended = session.snapshot(epoch: original)!
        precondition(suspended.activeInvocationCount == 1 && suspended.events == admitted.events)
        precondition(suspended.cancellationRequests.count == (cancelling ? 1 : 0))
        if let request = suspended.cancellationRequests.first {
            precondition(request.admission == attempt && request.ordinal > attempt.ordinal)
        }

        await gate.release()
        let result = await task.value
        let completed = session.snapshot(epoch: original)!
        precondition(completed.events.map(\.phase) == [.admitted, .returned] && completed.activeInvocationCount == 0)
        precondition(completed.cancellationRequests == suspended.cancellationRequests)
        let terminal = completed.events[1]
        precondition(terminal.invocationID == attempt.invocationID && terminal.mockID == attempt.mockID)
        precondition(terminal.epoch == original && terminal.ordinal > attempt.ordinal)
        if let request = completed.cancellationRequests.first { precondition(request.ordinal < terminal.ordinal) }

        if let instance = result {
            precondition(seed >= 0 && instance.label(3) == "21/3")
            precondition(instance.verify.label(.equal(3), phase: .returned).wasCalled(.once).passed)
            let ready = session.snapshot().events.last!
            precondition(ready.mockID != attempt.mockID && ready.phase == .returned)
            precondition(terminal.constructedMockID == ready.mockID)
            precondition(ready.mockID.rawValue == prior.rawValue + 1)
        } else {
            precondition(seed < 0 && terminal.constructedMockID == nil)
            precondition(session.makeMock().id.rawValue == prior.rawValue + 1)
            if cancelling { precondition(session.snapshot().events.isEmpty) }
        }
        let trace = try JSONSerialization.jsonObject(with: completed.exportTraceJSON()) as! [String: Any]
        let records = trace["records"] as! [[String: Any]]
        let kinds = records.compactMap { $0["kind"] as? String }
        precondition(kinds == (cancelling ? ["admitted", "cancellationRequested", "returned"] : ["admitted", "returned"]))
        precondition(records.last?["constructedMockID"] as? String == terminal.constructedMockID.map { String($0.rawValue) })
    }
}
