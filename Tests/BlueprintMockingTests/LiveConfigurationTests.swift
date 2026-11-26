import Testing
@testable import BlueprintMocking

private final class RuleLifetimeProbe: Sendable {
    private let onRetire: @Sendable () -> Void

    init(onRetire: @escaping @Sendable () -> Void) {
        self.onRetire = onRetire
    }

    func answer() -> String { "retired" }

    deinit {
        onRetire()
    }
}

private func monitoredPlan(
    onRetire: @escaping @Sendable () -> Void
) -> AsyncThrowingConfiguration<String, String, ServiceError> {
    let probe = RuleLifetimeProbe(onRetire: onRetire)
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.equal("unused")).willAnswer { _ in probe.answer() }
    return stubs.finish()
}

@Test func RUN014_liveReplacementKeepsFullAdmittedRevisionThroughSuspension() async throws {
    let issues = Issues()
    let (entries, entered) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let retired = CriticalState(0)

    func initialPlan() -> AsyncThrowingConfiguration<String, String, ServiceError> {
        let unrelated = RuleLifetimeProbe { retired.withLock { $0 += 1 } }
        let setup = AsyncThrowingStubbing<String, String, ServiceError>()
        setup.matching(.equal("unused")).willAnswer { _ in unrelated.answer() }
        setup.matching(.equal("call")).willAnswer { _ in
            entered.yield(())
            entered.finish()
            var gate = releases.makeAsyncIterator()
            _ = await gate.next()
            return "old"
        }
        return setup.finish()
    }

    let endpoint = AsyncThrowingEndpoint(id: EndpointID("live"),
                                        configuration: initialPlan(),
                                        failureReporter: issues.reporter)
    let oldCall = Task { try await endpoint.invoke("call") }
    var entry = entries.makeAsyncIterator()
    _ = await entry.next()
    #expect(endpoint.verification(matching: .any, phase: .admitted).wasCalled(.once).passed)

    let replacement = AsyncThrowingStubbing<String, String, ServiceError>()
    replacement.matching(.equal("call")).willReturn("new")
    let revision = endpoint.replaceConfiguration(replacement.finish())
    #expect(revision.rawValue == 1)
    #expect(retired.withLock { $0 } == 0)
    #expect(try await endpoint.invoke("call") == "new")
    #expect(endpoint.invocations.map(\.configurationRevision.rawValue) == [0, revision.rawValue])
    #expect(endpoint.invocations.map(\.phase) == [.admitted, .returned])

    release.yield(())
    release.finish()
    #expect(try await oldCall.value == "old")
    #expect(endpoint.invocations.map(\.phase) == [.returned, .returned])
    #expect(issues.values.isEmpty)
    #expect(retired.withLock { $0 } == 1)
}

@Test func RUN014_retiredPayloadDestructionCanReenterTheJournal() {
    let issues = Issues()
    let events = CriticalState<[Int]>([])
    let initial = AsyncThrowingStubbing<String, String, ServiceError>().finish()
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("reentrant"),
                                        configuration: initial,
                                        failureReporter: issues.reporter)

    let first = endpoint.replaceConfiguration(monitoredPlan { [weak endpoint] in
        let invocationCount = endpoint?.invocations.count ?? -1
        events.withLock { $0.append(invocationCount) }
    })
    #expect(first.rawValue == 1)
    #expect(events.withLock { $0 }.isEmpty)

    let second = endpoint.replaceConfiguration(initial)
    #expect(second.rawValue == 2)
    #expect(events.withLock { $0 } == [0])
    #expect(issues.values.isEmpty)
}
