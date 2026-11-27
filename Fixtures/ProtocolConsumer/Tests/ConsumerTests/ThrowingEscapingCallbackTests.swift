import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test(.timeLimit(.minutes(1)))
func GEN016_throwingEscapingCallbackPreservesItsDeclaredFailureDuringReplay() throws {
    let session = MockSession()
    let shadowed = ThrowingEscapingCallbackCaptor<Int, String, CallbackFixtureError>(session: session)
    let captor = ThrowingEscapingCallbackCaptor<Int, String, CallbackFixtureError>(session: session)
    let mock = ThrowingEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: shadowed)
            .willReturn("older")
        stubs.register(id: .equal("row"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    let received = StoredProperty<[Int]>([])
    let reply = registerThrowingEscapingCallback(mock, id: "row") { input throws(CallbackFixtureError) in
        #expect(session.snapshot().events.last?.phase == .returned)
        received.set(received.get() + [input])
        if input < 0 {
            throw .rejected(input)
        }
        return "delivered-\(input)"
    }
    #expect(reply == "registered")
    #expect(received.get().isEmpty)
    #expect(shadowed.captures.isEmpty)
    try #require(captor.captures.count == 1)

    let capture = try #require(captor.captures.first)
    let events = session.snapshot().events
    let admission = try #require(events.first { $0.phase == .admitted })
    #expect(capture.invocation == admission)
    #expect(events.map(\.phase) == [.admitted, .returned])

    let unavailableCalls = StoredProperty<Int>(0)
    func replay(_ input: Int) throws(CallbackFixtureError) -> String {
        try capture.invoke(input, onUnavailable: {
            unavailableCalls.set(unavailableCalls.get() + 1)
            return .unavailable
        })
    }

    #expect(try replay(17) == "delivered-17")
    #expect(throws: CallbackFixtureError.rejected(-11)) {
        try replay(-11)
    }
    #expect(try replay(23) == "delivered-23")
    #expect(received.get() == [17, -11, 23])
    #expect(unavailableCalls.get() == 0)
    #expect(session.snapshot().events == events)
    #expect(mock.verify.register(id: .equal("row"), phase: .returned).wasCalled(.once).passed)
}

private final class ThrowingCallbackPayload: Sendable {
    let label: String
    private let session: MockSession

    init(_ label: String, session: MockSession) {
        self.label = label
        self.session = session
    }

    deinit { _ = session.snapshot() }
}

@Test(.timeLimit(.minutes(1)))
func GEN016_throwingEscapingCallbackRetiresCapturesOnResetAndFinish() throws {
    let session = MockSession()
    let captor = ThrowingEscapingCallbackCaptor<Int, String, CallbackFixtureError>(session: session)
    let mock = ThrowingEscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .equal("row"))
            .capturingCallback(into: captor)
            .willReturn("registered")
    }

    weak var retained: ThrowingCallbackPayload?
    func install(_ label: String) -> String {
        let payload = ThrowingCallbackPayload(label, session: session)
        retained = payload
        return registerThrowingEscapingCallback(mock, id: "row") { input throws(CallbackFixtureError) in
            "\(payload.label)-\(input)"
        }
    }

    let unavailable = StoredProperty<[String]>([])
    #expect(install("old") == "registered")
    let old = try #require(captor.captures.first)
    #expect(retained != nil)
    #expect(try old.invoke(4, onUnavailable: { .unavailable }) == "old-4")

    let current = try session.resetHistory()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: CallbackFixtureError.unavailable) {
        try old.invoke(5, onUnavailable: {
            unavailable.set(unavailable.get() + ["reset"])
            return .unavailable
        })
    }

    #expect(install("fresh") == "registered")
    let fresh = try #require(captor.captures.first)
    #expect(fresh.invocation.epoch == current)
    #expect(retained != nil)
    #expect(try fresh.invoke(6, onUnavailable: { .unavailable }) == "fresh-6")

    _ = try session.finishIfQuiescent()
    #expect(captor.captures.isEmpty)
    #expect(retained == nil)
    #expect(throws: CallbackFixtureError.unavailable) {
        try fresh.invoke(7, onUnavailable: {
            unavailable.set(unavailable.get() + ["finish"])
            return .unavailable
        })
    }
    #expect(unavailable.get() == ["reset", "finish"])
}
