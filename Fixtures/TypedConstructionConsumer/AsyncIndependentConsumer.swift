import AsyncConstructorDomain
import BlueprintMocking
import Foundation

private let reporter = FailureReporter { issue in
    let line = "Async constructor issue: \(issue.message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

private actor SetupGate {
    private var preparation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspendSetup() async {
        await withCheckedContinuation { continuation in
            precondition(preparation == nil)
            preparation = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        if preparation != nil { return }
        await withCheckedContinuation { continuation in
            precondition(observer == nil)
            observer = continuation
        }
    }

    func release() {
        guard let preparation else { preconditionFailure("Setup did not suspend") }
        self.preparation = nil
        preparation.resume()
    }
}

@main struct AsyncIndependentConsumer {
    static func main() async throws {
        if let mode = CommandLine.arguments.dropFirst().first {
            try await checkInvalidScope(mode)
            return
        }
        try await checkConstruction(detachingEpoch: false)
        try await checkConstruction(detachingEpoch: true)
        print("PASS: GEN026 async construction stays active across suspension and links only after initialization")
    }

    private static func checkConstruction(detachingEpoch: Bool) async throws {
        let session = MockSession()
        let prior = session.snapshot().epoch
        let gate = SetupGate()
        let scope = AsyncConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: session
        ) { seed, stubs in
            precondition(session.snapshot().activeInvocationCount == 1)
            await gate.suspendSetup()
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
        }
        let task = Task.detached {
            await scope.withValue {
                await createAsyncDirectory(AsyncConstructionDirectoryMock.self, seed: 21)
            }
        }
        await gate.waitUntilSuspended()

        let suspended = session.snapshot()
        precondition(suspended.epoch == prior)
        precondition(suspended.activeInvocationCount == 1)
        precondition(suspended.events.map(\.phase) == [.admitted])
        let attempt = suspended.events[0]
        precondition(attempt.constructedMockID == nil)
        precondition(attempt.endpoint.rawValue.contains("|init(seed:Swift.Int) async->Self|"))
        do {
            _ = try session.resetHistory()
            preconditionFailure("Quiescent reset accepted an active constructor")
        } catch {
            precondition(error == .activeInvocations(count: 1))
        }
        do {
            _ = try session.finishIfQuiescent()
            preconditionFailure("Finish accepted an active constructor")
        } catch {
            precondition(error == .activeInvocations(count: 1))
        }
        if detachingEpoch {
            _ = try session.resetHistory(.detachActive)
            precondition(session.snapshot().epoch != prior)
            precondition(session.snapshot().events.isEmpty)
            precondition(session.snapshot(epoch: prior)?.events.map(\.phase) == [.admitted])
        }

        await gate.release()
        let instance = await task.value
        let construction = session.snapshot(epoch: prior)!
        precondition(construction.events.map(\.phase) == [.admitted, .returned])
        let terminal = construction.events[1]
        precondition(terminal.invocationID == attempt.invocationID && terminal.mockID == attempt.mockID)
        precondition(terminal.epoch == prior && terminal.ordinal > attempt.ordinal)
        guard let attached = terminal.constructedMockID else {
            preconditionFailure("Successful constructor did not attach its instance")
        }
        precondition(attached != terminal.mockID)
        precondition(instance.label(3) == "21/3")
        precondition(instance.verify.label(.equal(3), phase: .returned).wasCalled(.once).passed)
        let complete = try session.finishIfQuiescent()
        precondition(complete.activeInvocationCount == 0)
        precondition(complete.events.suffix(2).map(\.phase) == [.admitted, .returned])
        precondition(complete.events.suffix(2).allSatisfy { $0.mockID == attached && $0.epoch == complete.epoch })

        let trace = try JSONSerialization.jsonObject(with: construction.exportTraceJSON()) as! [String: Any]
        let records = trace["records"] as! [[String: Any]]
        precondition(records[0]["constructedMockID"] == nil)
        precondition(records[1]["constructedMockID"] as? String == String(attached.rawValue))
    }

    private static func checkInvalidScope(_ mode: String) async throws {
        let session = MockSession()
        let scope = AsyncConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: session
        ) { _, _ in preconditionFailure("Invalid scope ran setup") }
        switch mode {
        case "unscoped":
            _ = await createAsyncDirectory(AsyncConstructionDirectoryMock.self, seed: 1)
        case "unbound-detached":
            _ = await scope.withValue {
                await Task.detached {
                    await createAsyncDirectory(AsyncConstructionDirectoryMock.self, seed: 1)
                }.value
            }
        case "stale":
            _ = try session.resetHistory()
            _ = await scope.withValue { await createAsyncDirectory(AsyncConstructionDirectoryMock.self, seed: 1) }
        case "finished":
            _ = try session.finishIfQuiescent()
            _ = await scope.withValue { await createAsyncDirectory(AsyncConstructionDirectoryMock.self, seed: 1) }
        default:
            preconditionFailure("Unknown fixture mode")
        }
    }
}
