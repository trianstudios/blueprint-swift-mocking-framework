import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class MainActorAsyncCallbackPayload {
    let label: String
    private(set) var events: [String] = []

    init(_ label: String) {
        self.label = label
    }

    func enter(_ input: Int) {
        MainActor.preconditionIsolated()
        events.append("entered-\(input)")
    }

    func complete(_ input: Int) -> String {
        MainActor.preconditionIsolated()
        events.append("resumed-\(input)")
        return label + ":" + events.joined(separator: ",")
    }
}

private func replayMainActorAsyncCallback(
    _ capture: MainActorAsyncEscapingCallbackCapture<Int, String>, input: Int
) async throws(CallbackDeliveryError) -> String {
    try await capture.invoke(input)
}

@MainActor
private func verifyMainActorAsyncCallbackRetirement(finishing: Bool) async throws {
    let session = MockSession()
    let captor = MainActorAsyncEscapingCallbackCaptor<Int, String>(session: session)
    let mock = MainActorAsyncEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .any)
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let gate = AsyncCallbackReplayGate()
    defer { gate.release() }

    @MainActor
    func install(_ id: String, pauseAt inputToPause: Int? = nil, track: (MainActorAsyncCallbackPayload) -> Void)
        async -> String {
        let payload = MainActorAsyncCallbackPayload(id)
        track(payload)
        let callback: @MainActor @Sendable (Int) async -> String = { input in
            payload.enter(input)
            if inputToPause == input {
                await gate.pause()
            }
            return payload.complete(input)
        }
        return await Task.detached {
            registerMainActorAsyncEscapingCallback(mock, id: id, using: callback)
        }.value
    }

    weak var runningPayload: MainActorAsyncCallbackPayload?
    weak var idlePayload: MainActorAsyncCallbackPayload?
    let runningRegistration = await install("running", pauseAt: 41) { runningPayload = $0 }
    let idleRegistration = await install("idle") { idlePayload = $0 }
    #expect(runningRegistration == "registered")
    #expect(idleRegistration == "registered")
    #expect(runningPayload?.events == [])
    #expect(idlePayload?.events == [])

    let captures = captor.captures
    try #require(captures.count == 2)
    let acquired = captures[0]
    let idle = captures[1]
    let registered = session.snapshot()
    #expect(registered.activeInvocationCount == 0)
    #expect(registered.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(captures.map(\.invocation) == registered.events.filter { $0.phase == .admitted })
    #expect(mock.verify.register(id: .equal("running"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.register(id: .equal("idle"), phase: .returned).wasCalled(.once).passed)

    let completed = StoredProperty<Bool>(false)
    let running = Task.detached {
        let response = try await replayMainActorAsyncCallback(acquired, input: 41)
        completed.set(true)
        return response
    }
    try #require(await gate.waitUntilPaused())
    #expect(runningPayload?.events == ["entered-41"])
    #expect(!completed.get())
    #expect(session.snapshot() == registered)

    if finishing {
        let closed = try session.finishIfQuiescent()
        #expect(closed.isFinished)
        #expect(closed.activeInvocationCount == 0)
        #expect(closed.events == registered.events)
    } else {
        let epoch = try session.resetHistory()
        #expect(epoch != registered.epoch)
        #expect(session.snapshot().events.isEmpty)
    }
    let retired = session.snapshot()
    #expect(captor.captures.isEmpty)
    #expect(idlePayload == nil)
    #expect(runningPayload?.events == ["entered-41"])
    #expect(!completed.get())

    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await replayMainActorAsyncCallback(acquired, input: 42)
    }
    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await replayMainActorAsyncCallback(idle, input: 43)
    }
    #expect(runningPayload?.events == ["entered-41"])

    gate.release()
    #expect(try await running.value == "running:entered-41,resumed-41")
    #expect(completed.get())
    #expect(runningPayload == nil)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorAsyncEscapingCallbackReplaySurvivesResetAfterAcquisition() async throws {
    try await verifyMainActorAsyncCallbackRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorAsyncEscapingCallbackReplaySurvivesFinishAfterAcquisition() async throws {
    try await verifyMainActorAsyncCallbackRetirement(finishing: true)
}
