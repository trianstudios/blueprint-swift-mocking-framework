import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private final class AsyncThrowingCallbackPayload: Sendable {
    let label: String
    private let session: MockSession

    init(_ label: String, session: MockSession) {
        self.label = label
        self.session = session
    }

    deinit { _ = session.snapshot() }
}

private func replayAsyncThrowingCallback(
    _ capture: AsyncThrowingEscapingCallbackCapture<Int, String, AsyncCallbackFixtureError>,
    input: Int,
    onUnavailable: @Sendable () -> AsyncCallbackFixtureError
) async throws(AsyncCallbackFixtureError) -> String {
    try await capture.invoke(input, onUnavailable: onUnavailable)
}

private func verifyTypedAsyncCallbackAcrossRetirement(finishing: Bool) async throws {
    let session = MockSession()
    let captor = AsyncThrowingEscapingCallbackCaptor<Int, String, AsyncCallbackFixtureError>(session: session)
    let mock = AsyncThrowingEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let input = finishing ? -19 : 19
    let gate = AsyncCallbackReplayGate()
    defer { gate.release() }
    let received = StoredProperty<[Int]>([])
    weak var retained: AsyncThrowingCallbackPayload?
    func install() -> String {
        let payload = AsyncThrowingCallbackPayload("callback", session: session)
        retained = payload
        return registerAsyncThrowingEscapingCallback(mock, id: "row") { value async throws(AsyncCallbackFixtureError) in
            received.set(received.get() + [value])
            if value == input {
                await gate.pause()
            }
            if value < 0 {
                throw .rejected(value)
            }
            return "\(payload.label)-\(value)"
        }
    }

    #expect(install() == "registered")
    #expect(received.get().isEmpty)
    #expect(retained != nil)
    try #require(captor.captures.count == 1)
    let capture = try #require(captor.captures.first)
    let registered = session.snapshot()
    #expect(registered.activeInvocationCount == 0)
    #expect(registered.events.map(\.phase) == [.admitted, .returned])
    #expect(registered.events.first == capture.invocation)
    #expect(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)

    let fallbackCalls = StoredProperty<[Int]>([])
    let completed = StoredProperty<Bool>(false)
    let running = Task { () async -> Result<String, AsyncCallbackFixtureError> in
        defer { completed.set(true) }
        do throws(AsyncCallbackFixtureError) {
            let answer = try await replayAsyncThrowingCallback(capture, input: input) {
                fallbackCalls.set(fallbackCalls.get() + [0])
                return .unavailable(0)
            }
            return .success(answer)
        } catch {
            return .failure(error)
        }
    }
    try #require(await gate.waitUntilPaused())
    #expect(received.get() == [input])
    #expect(!completed.get())
    #expect(fallbackCalls.get().isEmpty)
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
    #expect(retained != nil)
    #expect(!completed.get())

    let unavailableCode = finishing ? 97 : 96
    await #expect(throws: AsyncCallbackFixtureError.unavailable(unavailableCode)) {
        try await replayAsyncThrowingCallback(capture, input: 29) {
            #expect(session.snapshot() == retired)
            fallbackCalls.set(fallbackCalls.get() + [unavailableCode])
            return .unavailable(unavailableCode)
        }
    }
    #expect(fallbackCalls.get() == [unavailableCode])
    #expect(received.get() == [input])

    gate.release()
    let expected: Result<String, AsyncCallbackFixtureError> = finishing ? .failure(.rejected(input)) : .success("callback-19")
    #expect(await running.value == expected)
    #expect(completed.get())
    #expect(retained == nil)
    #expect(fallbackCalls.get() == [unavailableCode])
    #expect(received.get() == [input])
    #expect(session.snapshot() == retired)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_asyncThrowingEscapingCallbackReturnsAcrossResetAfterAcquisition() async throws {
    try await verifyTypedAsyncCallbackAcrossRetirement(finishing: false)
}

@Test(.timeLimit(.minutes(1)))
func GEN016_asyncThrowingEscapingCallbackThrowsItsDeclaredErrorAcrossFinish() async throws {
    try await verifyTypedAsyncCallbackAcrossRetirement(finishing: true)
}
