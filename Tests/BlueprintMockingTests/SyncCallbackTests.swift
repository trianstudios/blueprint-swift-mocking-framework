import Testing
@testable import BlueprintMocking

@Test func RUN011_checkedSyncCallbackUsesBorrowedCallerClosure() {
    let setup = SyncCallbackStubbing<String, Int, String, String>()
    setup.matching(.any).willReturn("default")
    setup.matching(.equal("twice")).willAnswer { _, callback in
        callback(2) + callback(3)
    }
    let endpoint = SyncCallbackEndpoint(
        id: EndpointID("callback.answer"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }
    )

    var arguments: [Int] = []
    func caller(_ value: Int) -> String {
        arguments.append(value)
        return "[\(value)]"
    }

    #expect(endpoint.invoke("twice", caller) == "[2][3]")
    #expect(endpoint.invoke("other", caller) == "default")
    #expect(arguments == [2, 3])
    #expect(endpoint.invocations.map(\.input) == ["twice", "other"])
    #expect(endpoint.verification(matching: .equal("twice"), phase: .returned).wasCalled(.once).passed)
}

@Test func RUN018_checkedSyncForwardingUsesOriginalCallbackAndTerminalOrigin() {
    let session = MockSession()
    let setup = SyncCallbackStubbing<String, Int, Int, Int>()
    setup.matching(.equal("stub")).willReturn(42)
    let endpoint = SyncCallbackEndpoint(
        id: EndpointID("callback.forward"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: { input, callback in callback(input.count) + 1 }
    )

    var seenArguments: [Int] = []
    func caller(_ value: Int) -> Int {
        let admission = session.snapshot().events.last
        #expect(admission?.phase == .admitted)
        #expect(admission?.origin == nil)
        seenArguments.append(value)
        return value * 2
    }

    #expect(endpoint.invoke("stub", caller) == 42)
    #expect(endpoint.invoke("real", caller) == 9)
    #expect(seenArguments == [4])
    #expect(endpoint.invocations.map(\.origin) == [nil, .forwarded])
    #expect(endpoint.verification(matching: .equal("real"), phase: .returned,
                                  origin: .forwarded).wasCalled(.once).passed)
    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.map(\.origin) == [nil, nil, nil, .forwarded])
    #expect(events.map(\.invocationID) ==
        endpoint.invocations.flatMap { [$0.sessionInvocationID, $0.sessionInvocationID] })
}

@Test func RUN011_checkedSyncCallbackFallbackNeverInvokesCallback() throws {
    let session = MockSession()
    let observed = CriticalState<[MockIssue.Kind]>([])
    let setup = SyncCallbackStubbing<Int, Int, Int, Int>()
    let endpoint = SyncCallbackEndpoint(
        id: EndpointID("callback.fallback"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in observed.withLock { $0.append(issue.kind) } },
        scope: session.makeMock(),
        fallback: { _ in -1 }
    )
    func unexpectedCallback(_ value: Int) -> Int {
        Issue.record("Fallback must not invoke the caller's callback")
        return value
    }

    #expect(endpoint.invoke(1, unexpectedCallback) == -1)
    #expect(endpoint.invocations.map(\.phase) == [.returned])
    try session.finishIfQuiescent()
    #expect(endpoint.invoke(2, unexpectedCallback) == -1)
    #expect(observed.withLock { $0 } == [.unexpectedCall, .unexpectedCall])
    #expect(endpoint.invocations.map(\.input) == [1])
}
