import BlueprintMocking
import Dispatch
import Testing

private enum PinnedLayeredRuleError: Error {
    case unexpected
}

@Test(.timeLimit(.minutes(1)))
func RUN013_admittedMatchingKeepsPinnedOverlayAcrossDetachedReset() async throws {
    let session = MockSession()
    let scope = session.makeMock()
    let id = EndpointID("layered.pinned")
    let entered = AsyncStream<Bool>.makeStream()
    let releaseMatcher = DispatchSemaphore(value: 0)
    defer { releaseMatcher.signal() }

    let base = AsyncThrowingStubbing<Int, String, PinnedLayeredRuleError>()
    base.matching(.any).willAnswer { "base/\($0)" }
    let overlay = AsyncThrowingStubbing<Int, String, PinnedLayeredRuleError>()
    overlay.matching(Matcher { input in
        if input == 41 {
            entered.continuation.yield(true)
            return releaseMatcher.wait(timeout: .now() + .seconds(30)) == .success
        }
        return true
    }).willAnswer { "scoped/\($0)" }
    let plan = overlay.finish()
    let endpoint = AsyncThrowingEndpoint(
        id: id,
        configuration: base.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") },
        scope: scope,
        failureMapping: { _ in .unexpected }
    )
    let held = Task.detached {
        defer { entered.continuation.finish() }
        return try await endpoint.withScopedConfiguration(plan) {
            try await endpoint.invoke(41)
        }
    }
    var arrivals = entered.stream.makeAsyncIterator()
    let matching = await arrivals.next()
    try #require(matching == true)

    let original = session.snapshot()
    #expect(original.activeInvocationCount == 1)
    try #require(original.events.count == 1)
    let heldAdmission = original.events[0]
    #expect(heldAdmission.phase == .admitted)
    #expect(heldAdmission.mockID == scope.id)
    #expect(heldAdmission.endpoint == id)

    let currentEpoch = try session.resetHistory(.detachActive)
    #expect(currentEpoch != original.epoch)
    #expect(session.snapshot().events.isEmpty)
    let archivedWhileHeld = try #require(session.snapshot(epoch: original.epoch))
    #expect(archivedWhileHeld.activeInvocationCount == 1)
    #expect(archivedWhileHeld.events == [heldAdmission])
    let fresh = try await endpoint.invoke(73)
    #expect(fresh == "base/73")
    let beforeOldCompletion = session.snapshot()
    #expect(beforeOldCompletion.epoch == currentEpoch)
    #expect(beforeOldCompletion.activeInvocationCount == 0)
    #expect(beforeOldCompletion.events.map(\.phase) == [.admitted, .returned])
    #expect(endpoint.invocations.map(\.input) == [73])

    releaseMatcher.signal()
    let old = try await held.value
    #expect(old == "scoped/41")

    let archived = try #require(session.snapshot(epoch: original.epoch))
    #expect(archived.activeInvocationCount == 0)
    #expect(archived.events.map(\.phase) == [.admitted, .returned])
    #expect(archived.events.first == heldAdmission)
    let terminal = try #require(archived.events.last)
    #expect(terminal.invocationID == heldAdmission.invocationID)
    #expect(terminal.endpoint == heldAdmission.endpoint)
    #expect(terminal.mockID == heldAdmission.mockID)
    #expect(terminal.epoch == heldAdmission.epoch)
    #expect(terminal.configurationRevision == heldAdmission.configurationRevision)
    #expect(terminal.ordinal > beforeOldCompletion.watermark)
    #expect(session.snapshot().events == beforeOldCompletion.events)
    #expect(endpoint.invocations.map(\.input) == [73])
}
