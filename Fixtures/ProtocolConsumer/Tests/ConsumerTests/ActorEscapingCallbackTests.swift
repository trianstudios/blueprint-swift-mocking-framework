import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class ActorEscapingCallbackPayload {
    let label: String
    var inputs: [Int] = []

    init(_ label: String) {
        self.label = label
    }

    func receive(_ value: Int) -> String {
        MainActor.preconditionIsolated()
        inputs.append(value)
        return "\(label)-\(value)"
    }
}

@Test @MainActor func GEN016_actorEscapingCallbackReplaysOnMainActorAfterDetachedRegistration() async throws {
    let session = MockSession()
    let shadowed = MainActorEscapingCallbackCaptor<Int, String>(session: session)
    let selected = MainActorEscapingCallbackCaptor<Int, String>(session: session)
    let mock = ActorEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: shadowed)
            .willReturn("older")
        stubs.register(id: .equal("row"))
            .capturingCallback(into: selected)
            .willReturn("selected")
    }

    let recipient = ActorEscapingCallbackPayload("actor")
    let callback: @MainActor @Sendable (Int) -> String = { input in
        recipient.receive(input)
    }
    let answer = await Task.detached {
        registerActorEscapingCallback(mock, id: "row", using: callback)
    }.value
    #expect(answer == "selected")
    #expect(recipient.inputs.isEmpty)
    #expect(shadowed.captures.isEmpty)
    try #require(selected.captures.count == 1)

    let capture = try #require(selected.captures.first)
    let admission = try #require(session.snapshot().events.first { $0.phase == .admitted })
    #expect(capture.invocation == admission)
    let replay = try await Task.detached {
        try await capture.invoke(17)
    }.value
    #expect(replay == "actor-17")
    #expect(recipient.inputs == [17])
    #expect(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
}

@Test @MainActor func GEN016_actorEscapingCallbackReleasesPayloadAcrossResetAndFinish() throws {
    let session = MockSession()
    let captor = MainActorEscapingCallbackCaptor<Int, String>(session: session)
    let mock = ActorEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    weak var retained: ActorEscapingCallbackPayload?
    func install(_ label: String) -> String {
        let payload = ActorEscapingCallbackPayload(label)
        retained = payload
        return registerActorEscapingCallback(mock, id: "row") { value in
            payload.receive(value)
        }
    }

    #expect(install("old") == "registered")
    let old = try #require(captor.captures.first)
    #expect(retained != nil)
    #expect(try old.invoke(4) == "old-4")

    let current = try session.resetHistory()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: CallbackDeliveryError.unavailable) {
        try old.invoke(5)
    }

    #expect(install("fresh") == "registered")
    let fresh = try #require(captor.captures.first)
    #expect(fresh.invocation.epoch == current)
    #expect(retained != nil)
    #expect(try fresh.invoke(6) == "fresh-6")

    _ = try session.finishIfQuiescent()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: CallbackDeliveryError.unavailable) {
        try fresh.invoke(7)
    }
}
