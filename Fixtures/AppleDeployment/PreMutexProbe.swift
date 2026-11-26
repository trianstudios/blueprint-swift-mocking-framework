private enum ProbeFailure: Error, Equatable { case offline }

private final class LocalValue {
    var number = 0
}

@MainActor
@main
struct PreMutexProbe {
    static func main() async throws {
        if #available(iOS 18, *) { fatalError("Expected a pre-Mutex iOS runtime") }
        let updates = CriticalState(0)
        precondition(!updates.usesMutex)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 { updates.withLock { $0 += 1 } }
                }
            }
        }
        precondition(updates.withLock { $0 } == 800)
        let reporter = FailureReporter { issue in fatalError(issue.message) }

        let stubs = AsyncThrowingStubbing<Int, Int, ProbeFailure>()
        stubs.matching(.any).willAnswer { value async throws(ProbeFailure) in
            if value < 0 { throw .offline }
            return value + 1
        }
        let endpoint = AsyncThrowingEndpoint(
            id: EndpointID("ios-sendable"),
            configuration: stubs.finish(),
            failureReporter: reporter
        )
        let result = try await endpoint.invoke(41)
        precondition(result == 42)
        do {
            _ = try await endpoint.invoke(-1)
            fatalError("Expected offline")
        } catch {
            precondition(error == .offline)
        }
        precondition(endpoint.verification(matching: .equal(-1), phase: .threw).wasCalled(.once).passed)

        let local = LocalValue()
        let actorStubs = MainActorAsyncThrowingStubbing<LocalValue, LocalValue, ProbeFailure>()
        actorStubs.matching(.any).willAnswer { input async throws(ProbeFailure) in
            await Task.yield()
            input.number = 42
            return input
        }
        let actorEndpoint = MainActorAsyncThrowingEndpoint(
            id: EndpointID("ios-main-actor"),
            configuration: actorStubs.finish(),
            failureReporter: reporter
        )
        let value = try await actorEndpoint.invoke(local)
        precondition(value === local && value.number == 42)
        precondition(actorEndpoint.verification(matching: .any).wasCalled(.once).passed)
        print("PASS pre-Mutex iOS runtime with automatic NSLock and typed Sendable/MainActor answers")
    }
}
