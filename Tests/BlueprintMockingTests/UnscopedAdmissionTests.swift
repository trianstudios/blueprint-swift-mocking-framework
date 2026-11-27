import BlueprintMocking
import Dispatch
import Testing

@Test(.timeLimit(.minutes(1)))
func unscopedAdmissionWakesObserverBeforeAnswerAndCompletesItsOriginalEpoch() async throws {
    let session = MockSession()
    let originalEpoch = session.snapshot().epoch
    let observer = session.observeChanges()
    defer { observer.cancel() }
    let release = DispatchSemaphore(value: 0)
    let setup = SyncStubbing<Int, Int>()
    setup.matching(.equal(7)).willAnswer { value in
        release.wait()
        return value + 1
    }
    let endpoint = SyncEndpoint(
        id: EndpointID("unscoped-admission"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock()
    )
    let call = Task.detached { endpoint.invoke(7) }
    defer { release.signal() }

    var notifications = observer.notifications.makeAsyncIterator()
    let notification = await notifications.next()
    try #require(notification != nil)
    let replay = try session.replay(since: observer.checkpoint)
    let admission = try #require(replay.events.first)
    #expect(replay.events == [admission])
    #expect(admission.phase == .admitted)
    #expect(admission.epoch == originalEpoch)
    #expect(session.snapshot().activeInvocationCount == 1)
    #expect(endpoint.verification(matching: .equal(7)).wasCalled(.once).passed)

    let newEpoch = try session.resetHistory(.detachActive)
    release.signal()
    #expect(await call.value == 8)
    let previous = try #require(session.snapshot(epoch: originalEpoch))
    #expect(previous.events.map(\.phase) == [.admitted, .returned])
    #expect(previous.events.allSatisfy { $0.invocationID == admission.invocationID })
    #expect(previous.activeInvocationCount == 0)
    #expect(session.snapshot().epoch == newEpoch)
    #expect(session.snapshot().events.isEmpty)
    #expect(endpoint.invocations.isEmpty)
}
