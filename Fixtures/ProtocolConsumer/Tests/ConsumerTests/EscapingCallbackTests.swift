import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test(.timeLimit(.minutes(1)))
func GEN016_escapingCallbackCapturesOnlyTheLatestWinningRule() throws {
    let session = MockSession()
    let shadowed = EscapingCallbackCaptor<Int, String>(session: session)
    let selected = EscapingCallbackCaptor<Int, String>(session: session)
    let unrelated = EscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: shadowed)
            .willReturn("older")
        stubs.register(id: .equal("row"))
            .capturingCallback(into: selected)
            .willReturn("selected")
        stubs.register(id: .equal("other"))
            .capturingCallback(into: unrelated)
            .willReturn("unmatched")
    }

    let received = StoredProperty<[Int]>([])
    let answer = registerEscapingCallback(mock, id: "row") { input in
        #expect(session.snapshot().events.last?.phase == .returned)
        received.set(received.get() + [input])
        return "delivered-\(input)"
    }
    #expect(answer == "selected")
    #expect(received.get().isEmpty)
    #expect(shadowed.captures.isEmpty)
    #expect(unrelated.captures.isEmpty)
    try #require(selected.captures.count == 1)
    let capture = try #require(selected.captures.first)
    let admission = try #require(session.snapshot().events.first { $0.phase == .admitted })
    #expect(capture.invocation == admission)
    #expect(try capture.invoke(29) == "delivered-29")
    #expect(received.get() == [29])
    #expect(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.register(id: .equal("other")).wasCalled(.never).passed)
}

private final class EscapingCallbackPayload: Sendable {
    let label: String
    private let session: MockSession

    init(_ label: String, session: MockSession) {
        self.label = label
        self.session = session
    }

    deinit { _ = session.snapshot() }
}

@Test(.timeLimit(.minutes(1)))
func GEN016_escapingCallbackLifetimeFollowsCaptureSelectionAndSessionEpoch() throws {
    let session = MockSession()
    let captor = EscapingCallbackCaptor<Int, String>(session: session)
    let mock = EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("plain")).willReturn("plain")
        stubs.register(id: .equal("capture"))
            .capturingCallback(into: captor)
            .willReturn("captured")
    }

    weak var retained: EscapingCallbackPayload?
    func install(_ id: String, label: String) -> String {
        let payload = EscapingCallbackPayload(label, session: session)
        retained = payload
        return registerEscapingCallback(mock, id: id) { input in
            "\(payload.label)-\(input)"
        }
    }

    #expect(install("plain", label: "discarded") == "plain")
    #expect(retained == nil)
    #expect(captor.captures.isEmpty)

    #expect(install("capture", label: "old") == "captured")
    let old = try #require(captor.captures.first)
    #expect(retained != nil)
    #expect(try old.invoke(4) == "old-4")

    let current = try session.resetHistory()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: CallbackDeliveryError.unavailable) {
        try old.invoke(5)
    }

    #expect(install("capture", label: "fresh") == "captured")
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
