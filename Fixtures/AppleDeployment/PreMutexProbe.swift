private enum ProbeFailure: Error, Equatable { case offline }

private final class LocalValue {
    var number = 0
}

private final class MatcherProbeReference: Sendable, Equatable {
    let value: Int

    init(_ value: Int) { self.value = value }

    static func == (lhs: MatcherProbeReference, rhs: MatcherProbeReference) -> Bool {
        lhs.value == rhs.value
    }
}

private enum MatcherProbeEvent: Sendable {
    case selected(Int?)
    case ignored
}

private enum ActorMatcherProbeEvent {
    case selected(LocalValue)
    case ignored
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

        let replacement = AsyncThrowingStubbing<Int, Int, ProbeFailure>()
        replacement.matching(.any).willReturn(100)
        let replacementPlan = replacement.finish()
        let revision = try endpoint.replaceConfigurationIfQuiescent(replacementPlan)
        let updated = try await endpoint.invoke(5)
        precondition(revision.rawValue == 1 && updated == 100)
        precondition(endpoint.invocations.map(\.configurationRevision.rawValue) == [0, 0, 1])
        print("PASS RUN-035 quiescent replacement on pre-Mutex iOS")
        let awaited = try await endpoint.replaceConfigurationWhenQuiescent(replacementPlan, within: .seconds(5))
        let latest = try await endpoint.invoke(5)
        precondition(awaited.rawValue == 2 && latest == 100)
        precondition(endpoint.invocations.last?.configurationRevision == awaited)
        print("PASS RUN-035 deadline-based replacement on pre-Mutex iOS")

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
        verifyCaseMatching()
        print("PASS pre-Mutex iOS runtime with automatic NSLock and typed Sendable/MainActor answers")
    }

    private static func verifyCaseMatching() {
        let first = MatcherProbeReference(42)
        let equalButSeparate = MatcherProbeReference(42)
        precondition(Matcher<MatcherProbeReference>.equal(first).matches(equalButSeparate))
        precondition(Matcher<MatcherProbeReference>.identical(to: first).matches(first))
        precondition(!Matcher<MatcherProbeReference>.identical(to: first).matches(equalButSeparate))

        let selectedNil = Matcher<MatcherProbeEvent>.projecting({ event -> Int?? in
            guard case let .selected(value) = event else { return nil }
            return .some(value)
        }, matching: .isNil())
        precondition(selectedNil.matches(.selected(nil)))
        precondition(!selectedNil.matches(.selected(42)))
        precondition(!selectedNil.matches(.ignored))

        let actorLocal = LocalValue()
        let localIdentity = MainActorMatcher<ActorMatcherProbeEvent>.projecting({ event in
            guard case let .selected(value) = event else { return nil }
            return value
        }, matching: .identical(to: actorLocal))
        precondition(localIdentity.matches(.selected(actorLocal)))
        precondition(!localIdentity.matches(.selected(LocalValue())))
        precondition(!localIdentity.matches(.ignored))
        print("PASS RUN-006 equality, identity and typed case projection on pre-Mutex iOS")
    }
}
