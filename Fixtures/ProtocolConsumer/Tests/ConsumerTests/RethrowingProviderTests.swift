import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct CallingRethrowingProvider: RethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: (Int) throws -> String) rethrows -> String {
        try callback(17)
    }
}

private struct ConstantRethrowingProvider: RethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: (Int) throws -> String) rethrows -> String {
        "constant"
    }
}

private final class RethrowingCallbackPayload {
    let label = "local"
}

private final class RethrowingCallbackFailure: Error {}

@Test(.timeLimit(.minutes(1)))
@MainActor
func GEN015_RUN005_generatedRethrowsProviderPreservesNonescapingCallbackAndError() throws {
    let session = MockSession()
    let mock = RethrowingDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: CallingRethrowingProvider()
    ) { stubs in
        stubs.label(for: .equal("row")).willReturn("label-row")
    }
    let directory: any RethrowingDirectory = mock
    var inputs: [Int] = []
    weak var observedPayload: RethrowingCallbackPayload?

    func applyWithLocalPayload() -> String {
        let payload = RethrowingCallbackPayload()
        observedPayload = payload
        return directory.apply { value in
            MainActor.preconditionIsolated()
            inputs.append(value)
            let during = session.snapshot()
            #expect(during.events.map(\.phase) == [.admitted])
            #expect(during.activeInvocationCount == 1)
            return "\(payload.label)-\(value)"
        }
    }

    #expect(session.snapshot().events.isEmpty)
    #expect(applyWithLocalPayload() == "local-17")
    #expect(inputs == [17])
    #expect(observedPayload == nil)

    let expected = RethrowingCallbackFailure()
    do {
        _ = try directory.apply { (_: Int) throws(RethrowingCallbackFailure) -> String in
            throw expected
        }
        Issue.record("Expected the caller's original error")
    } catch {
        #expect((error as? RethrowingCallbackFailure) === expected)
    }

    #expect(directory.label(for: "row") == "label-row")
    #expect(mock.verify.label(for: .equal("row"), phase: .returned).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 6)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw, .admitted, .returned])
    let rethrowing = events[0].endpoint
    #expect(rethrowing.rawValue.contains("ConsumerDomain.RethrowingDirectory|apply("))
    #expect(rethrowing.rawValue.contains(" rethrows"))
    #expect(events.prefix(4).allSatisfy { $0.endpoint == rethrowing })
    #expect(events[4].endpoint != rethrowing)
    #expect(events[4].endpoint == events[5].endpoint)
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[4].invocationID == events[5].invocationID)
    #expect(Set([events[0], events[2], events[4]].map(\.invocationID)).count == 3)
}

@Test func GEN015_RUN005_constantRethrowsProviderCanSkipCallerCallback() throws {
    let session = MockSession()
    let mock = RethrowingDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: ConstantRethrowingProvider()
    ) { _ in }
    let directory: any RethrowingDirectory = mock
    var callbackCount = 0

    let nonthrowing = directory.apply { _ in
        callbackCount += 1
        return "unexpected"
    }
    let throwing = try directory.apply { (_: Int) throws(RethrowingCallbackFailure) -> String in
        callbackCount += 1
        throw RethrowingCallbackFailure()
    }
    #expect(nonthrowing == "constant")
    #expect(throwing == "constant")
    #expect(callbackCount == 0)

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
}
