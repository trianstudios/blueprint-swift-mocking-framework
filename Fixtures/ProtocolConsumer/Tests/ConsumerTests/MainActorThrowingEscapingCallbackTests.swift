import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class MainActorThrowingCallbackPayload {
    let label: String
    private(set) var inputs: [Int] = []

    init(_ label: String) {
        self.label = label
    }

    func receive(_ input: Int) throws(MainActorCallbackFixtureError) -> String {
        MainActor.preconditionIsolated()
        inputs.append(input)
        if input < 0 {
            throw .rejected(input)
        }
        return "\(label)-\(input)"
    }
}

@MainActor
private final class MainActorUnavailableTrace {
    private(set) var calls: [String] = []

    func unavailable(_ label: String, session: MockSession) -> MainActorCallbackFixtureError {
        MainActor.preconditionIsolated()
        _ = session.snapshot()
        calls.append(label)
        return .unavailable
    }
}

private func replayMainActorThrowingCallback(
    _ capture: MainActorThrowingEscapingCallbackCapture<Int, String, MainActorCallbackFixtureError>,
    input: Int,
    onUnavailable: @MainActor @Sendable () -> MainActorCallbackFixtureError
) async throws(MainActorCallbackFixtureError) -> String {
    try await capture.invoke(input, onUnavailable: onUnavailable)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorThrowingEscapingCallbackPreservesActorAndDeclaredError() async throws {
    let session = MockSession()
    let shadowed = MainActorThrowingEscapingCallbackCaptor<Int, String, MainActorCallbackFixtureError>(session: session)
    let selected = MainActorThrowingEscapingCallbackCaptor<Int, String, MainActorCallbackFixtureError>(session: session)
    let mock = MainActorThrowingEscapingCallbackDirectoryMock(
        failureReporter: .swiftTesting, session: session
    ) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: shadowed)
            .willReturn("older")
        stubs.register(id: .equal("row"))
            .capturingCallback(into: selected)
            .willReturn("registered")
    }

    let recipient = MainActorThrowingCallbackPayload("actor")
    let callback: @MainActor @Sendable (Int) throws(MainActorCallbackFixtureError) -> String = {
        input throws(MainActorCallbackFixtureError) in
        #expect(session.snapshot().events.last?.phase == .returned)
        return try recipient.receive(input)
    }
    let registered = await Task.detached {
        registerMainActorThrowingEscapingCallback(mock, id: "row", using: callback)
    }.value
    #expect(registered == "registered")
    #expect(recipient.inputs.isEmpty)
    #expect(shadowed.captures.isEmpty)
    try #require(selected.captures.count == 1)

    let capture = try #require(selected.captures.first)
    let timeline = session.snapshot()
    #expect(timeline.events.map(\.phase) == [.admitted, .returned])
    #expect(timeline.events.first == capture.invocation)
    #expect(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)

    let fallback = MainActorUnavailableTrace()
    let onUnavailable: @MainActor @Sendable () -> MainActorCallbackFixtureError = {
        fallback.unavailable("unexpected", session: session)
    }
    let replayed = try await Task.detached {
        try await replayMainActorThrowingCallback(capture, input: 23, onUnavailable: onUnavailable)
    }.value
    #expect(replayed == "actor-23")
    await #expect(throws: MainActorCallbackFixtureError.rejected(-17)) {
        try await Task.detached {
            try await replayMainActorThrowingCallback(capture, input: -17, onUnavailable: onUnavailable)
        }.value
    }
    #expect(recipient.inputs == [23, -17])
    #expect(fallback.calls.isEmpty)
    #expect(session.snapshot() == timeline)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func GEN016_mainActorThrowingEscapingCallbackRetiresPayloadOnResetAndFinish() async throws {
    let session = MockSession()
    let captor = MainActorThrowingEscapingCallbackCaptor<Int, String, MainActorCallbackFixtureError>(session: session)
    let mock = MainActorThrowingEscapingCallbackDirectoryMock(
        failureReporter: .swiftTesting, session: session
    ) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    weak var retained: MainActorThrowingCallbackPayload?
    @MainActor
    func install(_ label: String) async -> String {
        let payload = MainActorThrowingCallbackPayload(label)
        retained = payload
        let callback: @MainActor @Sendable (Int) throws(MainActorCallbackFixtureError) -> String = {
            input throws(MainActorCallbackFixtureError) in
            try payload.receive(input)
        }
        return await Task.detached {
            registerMainActorThrowingEscapingCallback(mock, id: "row", using: callback)
        }.value
    }

    let trace = MainActorUnavailableTrace()
    #expect(await install("old") == "registered")
    let old = try #require(captor.captures.first)
    #expect(retained != nil)
    #expect(try old.invoke(4, onUnavailable: { trace.unavailable("unexpected", session: session) }) == "old-4")

    let current = try session.resetHistory()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    let afterReset = session.snapshot()
    #expect(throws: MainActorCallbackFixtureError.unavailable) {
        try old.invoke(5, onUnavailable: {
            #expect(session.snapshot() == afterReset)
            return trace.unavailable("reset", session: session)
        })
    }

    #expect(await install("fresh") == "registered")
    let fresh = try #require(captor.captures.first)
    #expect(fresh.invocation.epoch == current)
    #expect(retained != nil)
    #expect(try fresh.invoke(6, onUnavailable: { trace.unavailable("unexpected", session: session) }) == "fresh-6")

    let closed = try session.finishIfQuiescent()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: MainActorCallbackFixtureError.unavailable) {
        try fresh.invoke(7, onUnavailable: {
            #expect(session.snapshot() == closed)
            return trace.unavailable("finish", session: session)
        })
    }
    #expect(trace.calls == ["reset", "finish"])
    #expect(session.snapshot() == closed)
}
