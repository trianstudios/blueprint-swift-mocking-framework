import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class MainActorAsyncThrowingCallbackTrace {
    private(set) var entered: [Int] = []
    private(set) var resumed: [Int] = []
    private(set) var unavailableCodes: [Int] = []

    func enter(_ input: Int) {
        MainActor.preconditionIsolated()
        entered.append(input)
    }

    func resume(_ input: Int) {
        MainActor.preconditionIsolated()
        resumed.append(input)
    }

    func unavailable(_ code: Int) -> MainActorAsyncCallbackFixtureError {
        MainActor.preconditionIsolated()
        unavailableCodes.append(code)
        return .unavailable(code)
    }
}

@MainActor
private final class MainActorAsyncThrowingCallbackPayload {
    let label: String
    private var completed: [Int] = []

    init(_ label: String) {
        self.label = label
    }

    func deliver(_ input: Int, trace: MainActorAsyncThrowingCallbackTrace)
        throws(MainActorAsyncCallbackFixtureError) -> String {
        MainActor.preconditionIsolated()
        trace.resume(input)
        completed.append(input)
        if input < 0 {
            throw .rejected(input)
        }
        return label + ":" + completed.map { String($0) }.joined(separator: ",")
    }
}

private func replayMainActorAsyncThrowingCallback(
    _ capture: MainActorAsyncThrowingEscapingCallbackCapture<Int, String, MainActorAsyncCallbackFixtureError>,
    input: Int,
    onUnavailable: @MainActor @Sendable () -> MainActorAsyncCallbackFixtureError
) async throws(MainActorAsyncCallbackFixtureError) -> String {
    try await capture.invoke(input, onUnavailable: onUnavailable)
}

@MainActor
private func verifyMainActorAsyncThrowingCallbackRetirement(finishing: Bool) async throws {
    let session = MockSession()
    let captor = MainActorAsyncThrowingEscapingCallbackCaptor<Int, String, MainActorAsyncCallbackFixtureError>(
        session: session
    )
    let mock = MainActorAsyncThrowingEscapingCallbackDirectoryMock(
        failureReporter: .swiftTesting, session: session
    ) { stubs in
        stubs.register(id: .any)
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let trace = MainActorAsyncThrowingCallbackTrace()
    let gate = AsyncCallbackReplayGate()
    defer { gate.release() }
    let input = finishing ? -19 : 19

    @MainActor
    func install(
        _ id: String, pauseAt inputToPause: Int? = nil, track: (MainActorAsyncThrowingCallbackPayload) -> Void
    ) async -> String {
        let payload = MainActorAsyncThrowingCallbackPayload(id)
        track(payload)
        let callback: @MainActor @Sendable (Int) async throws(MainActorAsyncCallbackFixtureError) -> String = {
            value async throws(MainActorAsyncCallbackFixtureError) in
            trace.enter(value)
            if inputToPause == value {
                await gate.pause()
            }
            return try payload.deliver(value, trace: trace)
        }
        return await Task.detached {
            registerMainActorAsyncThrowingEscapingCallback(mock, id: id, using: callback)
        }.value
    }

    weak var runningPayload: MainActorAsyncThrowingCallbackPayload?
    weak var idlePayload: MainActorAsyncThrowingCallbackPayload?
    let runningRegistration = await install("running", pauseAt: input) { runningPayload = $0 }
    let idleRegistration = await install("idle") { idlePayload = $0 }
    #expect(runningRegistration == "registered")
    #expect(idleRegistration == "registered")
    #expect(trace.entered.isEmpty)
    #expect(trace.resumed.isEmpty)
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
    let running = Task.detached { () async -> Result<String, MainActorAsyncCallbackFixtureError> in
        defer { completed.set(true) }
        do throws(MainActorAsyncCallbackFixtureError) {
            let answer = try await replayMainActorAsyncThrowingCallback(acquired, input: input) {
                trace.unavailable(0)
            }
            return .success(answer)
        } catch {
            return .failure(error)
        }
    }
    try #require(await gate.waitUntilPaused())
    #expect(trace.entered == [input])
    #expect(trace.resumed.isEmpty)
    #expect(trace.unavailableCodes.isEmpty)
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

    let unavailableCode = finishing ? 970 : 960
    await #expect(throws: MainActorAsyncCallbackFixtureError.unavailable(unavailableCode)) {
        try await replayMainActorAsyncThrowingCallback(acquired, input: 31) {
            #expect(session.snapshot() == retired)
            return trace.unavailable(unavailableCode)
        }
    }
    await #expect(throws: MainActorAsyncCallbackFixtureError.unavailable(unavailableCode + 1)) {
        try await replayMainActorAsyncThrowingCallback(idle, input: 37) {
            #expect(session.snapshot() == retired)
            return trace.unavailable(unavailableCode + 1)
        }
    }
    #expect(trace.unavailableCodes == [unavailableCode, unavailableCode + 1])
    #expect(trace.entered == [input])
    #expect(trace.resumed.isEmpty)

    gate.release()
    let expected: Result<String, MainActorAsyncCallbackFixtureError> =
        finishing ? .failure(.rejected(input)) : .success("running:19")
    #expect(await running.value == expected)
    #expect(completed.get())
    #expect(trace.entered == [input])
    #expect(trace.resumed == [input])
    #expect(trace.unavailableCodes == [unavailableCode, unavailableCode + 1])
    #expect(runningPayload == nil)
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorAsyncThrowingEscapingCallbackReturnsAcrossResetAfterAcquisition() async throws {
    try await verifyMainActorAsyncThrowingCallbackRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorAsyncThrowingEscapingCallbackThrowsItsDeclaredErrorAcrossFinish() async throws {
    try await verifyMainActorAsyncThrowingCallbackRetirement(finishing: true)
}
