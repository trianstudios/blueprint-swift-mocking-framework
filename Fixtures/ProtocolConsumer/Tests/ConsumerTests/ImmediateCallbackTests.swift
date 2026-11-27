import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private final class ImmediateCallbackPayload {
    let label = "local"
}

@MainActor
@Test func RUN011_generatedOrdinaryMockInvokesCallbackWithinWitness() throws {
    let session = MockSession()
    let mock = ImmediateCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.process(scope: .equal("batch"), .equal(7)).willAnswer { metadata, callback in
            "\(metadata.0):\(callback(metadata.1))"
        }
        stubs.ignore().willReturn("ignored")
    }
    let directory: any ImmediateCallbackDirectory = mock
    var inputs: [Int] = []
    weak var observedPayload: ImmediateCallbackPayload?

    func processWithLocalPayload() -> String {
        let payload = ImmediateCallbackPayload()
        observedPayload = payload
        return directory.process(scope: "batch", 7) { value in
            MainActor.preconditionIsolated()
            inputs.append(value)
            let during = session.snapshot()
            #expect(during.activeInvocationCount == 1)
            #expect(during.events.map(\.phase) == [.admitted])
            return "\(payload.label)-\(value)"
        }
    }

    #expect(session.snapshot().events.isEmpty)
    #expect(processWithLocalPayload() == "batch:local-7")
    #expect(inputs == [7])
    #expect(observedPayload == nil)
    #expect(directory.ignore { value in
        inputs.append(value)
        return "unexpected"
    } == "ignored")
    #expect(inputs == [7])

    let processed: Verification<(String, Int)> = mock.verify.process(
        scope: .equal("batch"), .equal(7), phase: .returned
    )
    let ignored: Verification<Void> = mock.verify.ignore(phase: .returned)
    #expect(processed.wasCalled(.once).passed)
    #expect(ignored.wasCalled(.once).passed)

    let completed = session.snapshot()
    try #require(completed.events.count == 4)
    #expect(completed.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(completed.events[0].invocationID == completed.events[1].invocationID)
    #expect(completed.events[2].invocationID == completed.events[3].invocationID)
    #expect(completed.events[0].invocationID != completed.events[2].invocationID)
    #expect(completed.activeInvocationCount == 0)
}
