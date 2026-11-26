import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct RealCallbackSpyDirectory: CallbackSpyDirectory {
    func transform(id: String, using callback: (Int) -> String) -> String {
        let first = callback(7)
        let second = callback(13)
        return "real:\(id):\(first),\(second)"
    }

    func withoutMetadata(_ callback: (Int) -> String) -> String {
        callback(11)
    }

    func summarize(_ id: String, offset: Int, using callback: (Int) -> String) -> String {
        id + ":" + callback(offset)
    }
}

private final class CallbackPayload {
    let label = "local"
}

@Test(.timeLimit(.minutes(1)))
func GEN017_RUN011_RUN018_generatedSpyRunsNonescapingCallbackDuringCall() throws {
    let session = MockSession()
    let spy = CallbackSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: RealCallbackSpyDirectory()
    ) { stubs in
        stubs.transform(id: .equal("stubbed")).willAnswer { id, callback in
            "stub:\(id):\(callback(37))"
        }
    }
    let directory: any CallbackSpyDirectory = spy
    var callbackInputs: [Int] = []
    weak var observedPayload: CallbackPayload?

    func invokeRealWithLocalPayload() -> String {
        let payload = CallbackPayload()
        observedPayload = payload
        return directory.transform(id: "forwarded") { value in
            callbackInputs.append(value)
            let snapshot = session.snapshot()
            #expect(snapshot.activeInvocationCount == 1)
            #expect(snapshot.events.last?.phase == .admitted)
            return "\(payload.label)-\(value)"
        }
    }

    #expect(invokeRealWithLocalPayload() == "real:forwarded:local-7,local-13")
    #expect(callbackInputs == [7, 13])
    #expect(observedPayload == nil)
    #expect(directory.transform(id: "stubbed") { value in
        callbackInputs.append(value)
        return "value-\(value)"
    } == "stub:stubbed:value-37")
    #expect(callbackInputs == [7, 13, 37])

    #expect(spy.verify.transform(id: .equal("forwarded"), phase: .returned, origin: .forwarded)
        .wasCalled(.once).passed)
    #expect(spy.verify.transform(id: .equal("stubbed"), phase: .returned).wasCalled(.once).passed)
    #expect(spy.verify.transform(id: .equal("stubbed"), origin: .forwarded).wasCalled(.never).passed)

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 4)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.map(\.origin) == [nil, .forwarded, nil, nil])
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
}

@Test @MainActor func GEN017_callbackSpyPreservesCallerIsolationAndTypedMetadata() {
    let spy = CallbackSpyDirectoryMock(failureReporter: .swiftTesting, forwardingTo: RealCallbackSpyDirectory()) { _ in }
    let directory: any CallbackSpyDirectory = spy
    var callerValues: [Int] = []

    let noMetadata = directory.withoutMetadata {
        MainActor.preconditionIsolated()
        callerValues.append($0)
        return String($0 * 2)
    }
    let tupleMetadata = directory.summarize("region", offset: 8) {
        MainActor.preconditionIsolated()
        callerValues.append($0)
        return String($0 * 3)
    }

    #expect(noMetadata == "22")
    #expect(tupleMetadata == "region:24")
    #expect(callerValues == [11, 8])
    #expect(spy.verify.withoutMetadata(phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(spy.verify.summarize(.equal("region"), offset: .equal(8),
                                phase: .returned, origin: .forwarded).wasCalled(.once).passed)
}
