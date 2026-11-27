import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private actor AsyncCallbackReplayGate {
    private let entered = AsyncStream<Void>.makeStream()
    private let opened = AsyncStream<Void>.makeStream()
    private var isPaused = false

    func waitUntilPaused() async -> Bool {
        for await _ in entered.stream {}
        // This actor-isolated read can run only after pause() yields the actor.
        return isPaused
    }

    func pause() async {
        isPaused = true
        entered.continuation.finish()
        for await _ in opened.stream {}
        isPaused = false
    }

    nonisolated func release() {
        opened.continuation.finish()
    }
}

private final class AsyncCallbackPayload: Sendable {
    let label: String
    private let session: MockSession

    init(_ label: String, session: MockSession) {
        self.label = label
        self.session = session
    }

    deinit { _ = session.snapshot() }
}

private func replayAsyncCallback(
    _ capture: AsyncEscapingCallbackCapture<Int, String>, input: Int
) async throws(CallbackDeliveryError) -> String {
    try await capture.invoke(input)
}

private func verifyAsyncCallbackRetirement(finishing: Bool) async throws {
    let session = MockSession()
    let captor = AsyncEscapingCallbackCaptor<Int, String>(session: session)
    let mock = AsyncEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .any)
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let gate = AsyncCallbackReplayGate()
    defer { gate.release() }
    let received = StoredProperty<[Int]>([])
    func install(_ id: String, pauseAt inputToPause: Int? = nil, track: (AsyncCallbackPayload) -> Void) -> String {
        let payload = AsyncCallbackPayload(id, session: session)
        track(payload)
        return registerAsyncEscapingCallback(mock, id: id) { input in
            received.set(received.get() + [input])
            if inputToPause == input {
                await gate.pause()
            }
            return "\(payload.label)-\(input)"
        }
    }

    weak var runningPayload: AsyncCallbackPayload?
    weak var idlePayload: AsyncCallbackPayload?
    #expect(install("running", pauseAt: 41) { runningPayload = $0 } == "registered")
    #expect(install("idle") { idlePayload = $0 } == "registered")
    #expect(received.get().isEmpty)
    #expect(runningPayload != nil)
    #expect(idlePayload != nil)

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
    let running = Task {
        let response = try await replayAsyncCallback(acquired, input: 41)
        completed.set(true)
        return response
    }
    try #require(await gate.waitUntilPaused())
    #expect(received.get() == [41])
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
    #expect(runningPayload != nil)
    #expect(!completed.get())

    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await replayAsyncCallback(acquired, input: 42)
    }
    await #expect(throws: CallbackDeliveryError.unavailable) {
        try await replayAsyncCallback(idle, input: 43)
    }
    #expect(received.get() == [41])

    gate.release()
    #expect(try await running.value == "running-41")
    #expect(completed.get())
    #expect(runningPayload == nil)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_asyncEscapingCallbackReplaySurvivesResetAfterAcquisition() async throws {
    try await verifyAsyncCallbackRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_asyncEscapingCallbackReplaySurvivesFinishAfterAcquisition() async throws {
    try await verifyAsyncCallbackRetirement(finishing: true)
}
