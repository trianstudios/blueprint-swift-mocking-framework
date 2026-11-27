import AsyncThrowingConstructorDomain
import BlueprintMocking

private actor SetupGate {
    private var awaitingRelease: CheckedContinuation<Void, Never>?
    private var awaitingSetup: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            awaitingRelease = continuation
            awaitingSetup?.resume()
            awaitingSetup = nil
        }
    }

    func waitForSetup() async {
        if awaitingRelease != nil { return }
        await withCheckedContinuation { awaitingSetup = $0 }
    }

    func release() {
        let pending = awaitingRelease!
        awaitingRelease = nil
        pending.resume()
    }
}

private enum Trial: CaseIterable, Sendable {
    case success, configuredFailure, cooperativeCancellation, ignoredCancellation

    var requestsCancellation: Bool {
        self == .cooperativeCancellation || self == .ignoredCancellation
    }

    func failure(seed: Int) -> AsyncConstructionFailure? {
        switch self {
        case .configuredFailure: .rejected(seed: seed)
        case .cooperativeCancellation: .interrupted(seed: seed)
        case .success, .ignoredCancellation: nil
        }
    }
}

@main struct AsyncThrowingIndependentConsumer {
    static func main() async throws {
        for trial in Trial.allCases { try await verify(trial) }
        print("PASS: GEN026 async typed construction preserves declared outcomes independently of cancellation")
    }

    private static func verify(_ trial: Trial) async throws {
        let session = MockSession()
        let epoch = session.snapshot().epoch
        let gate = SetupGate()
        let scope = AsyncThrowingConstructionDirectoryMock.makeConstructionScope(
            failureReporter: FailureReporter { issue in preconditionFailure(issue.message) },
            session: session
        ) { seed, stubs async throws(AsyncConstructionFailure) in
            await gate.suspend()
            precondition(Task.isCancelled == trial.requestsCancellation)
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
            if let failure = trial.failure(seed: seed) { throw failure }
        }
        let seed = 29
        let before = session.makeMock().id
        let pending = Task.detached { () -> Result<AsyncThrowingConstructionDirectoryMock, AsyncConstructionFailure> in
            do throws(AsyncConstructionFailure) {
                let instance = try await scope.withValue { () async throws(AsyncConstructionFailure) in
                    try await createAsyncThrowingDirectory(AsyncThrowingConstructionDirectoryMock.self, seed: seed)
                }
                return .success(instance)
            } catch {
                return .failure(error)
            }
        }
        await gate.waitForSetup()

        let admitted = session.snapshot()
        precondition(admitted.activeInvocationCount == 1 && admitted.events.map(\.phase) == [.admitted])
        let attempt = admitted.events[0]
        precondition(attempt.constructedMockID == nil)
        precondition(attempt.endpoint.rawValue.contains(
            "init(seed:Swift.Int) async throws(AsyncThrowingConstructorDomain.AsyncConstructionFailure)"
        ))
        precondition(admitted.cancellationRequests.isEmpty)
        if trial == .cooperativeCancellation {
            _ = try session.resetHistory(.detachActive)
        }
        if trial.requestsCancellation { pending.cancel() }
        let suspended = session.snapshot(epoch: epoch)!
        precondition(suspended.activeInvocationCount == 1 && suspended.events == admitted.events)
        precondition(suspended.cancellationRequests.count == (trial.requestsCancellation ? 1 : 0))
        if let request = suspended.cancellationRequests.first {
            precondition(request.admission == attempt && request.ordinal > attempt.ordinal)
        }

        await gate.release()
        let result = await pending.value
        let terminal = session.snapshot(epoch: epoch)!
        precondition(terminal.events.count == 2 && terminal.activeInvocationCount == 0)
        precondition(terminal.cancellationRequests == suspended.cancellationRequests)
        let completion = terminal.events[1]
        precondition(completion.invocationID == attempt.invocationID && completion.mockID == attempt.mockID)
        if let request = terminal.cancellationRequests.first { precondition(request.ordinal < completion.ordinal) }

        switch result {
        case .failure(let failure):
            precondition(failure == trial.failure(seed: seed))
            precondition(completion.phase == .threw && completion.constructedMockID == nil)
            precondition(session.makeMock().id.rawValue == before.rawValue + 1)
            if trial == .cooperativeCancellation {
                let current = session.snapshot()
                precondition(current.epoch != epoch && current.events.isEmpty && current.cancellationRequests.isEmpty)
            }
        case .success(let instance):
            precondition(trial.failure(seed: seed) == nil)
            precondition(completion.phase == .returned)
            precondition(instance.label(2) == "29/2")
            let invoked = session.snapshot().events.last!
            precondition(invoked.phase == .returned && invoked.mockID != attempt.mockID)
            precondition(completion.constructedMockID == invoked.mockID)
        }
    }
}
