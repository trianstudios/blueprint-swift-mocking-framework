import BlueprintMocking
import Testing

private final class ActorLocalBox {
    var value: String
    init(_ value: String) { self.value = value }
}

private enum ActorTestFailure: Error, Equatable { case offline }

@Test @MainActor func RUN020_mainActorSetupAndVerificationSupportLocalValues() {
    let request = ActorLocalBox("request")
    let stored = ActorLocalBox("response")
    let stubs = MainActorSyncStubbing<ActorLocalBox, ActorLocalBox>()
    stubs.matching(MainActorMatcher { $0 === request }).willAnswer { value in
        stored.value += " " + value.value
        return stored
    }
    let endpoint = MainActorSyncEndpoint(id: EndpointID("actor-local"),
                                         configuration: stubs.finish(),
                                         failureReporter: FailureReporter { _ in })
    let matchingRequest = MainActorMatcher<ActorLocalBox> { $0 === request }
    #expect(endpoint.verification(matching: matchingRequest).wasCalled(.never).passed)

    let result = endpoint.invoke(request)
    #expect(result === stored)
    #expect(stored.value == "response request")
    let verification = endpoint.verification(matching: matchingRequest, phase: .returned).wasCalled(.once)
    #expect(verification.passed)
    #expect(verification.invocationIDs == [1])
}

@Test @MainActor func RUN020_mainActorAsyncAnswersRetainIsolationAndTypedErrors() async throws {
    let response = ActorLocalBox("first")
    let stubs = MainActorAsyncThrowingStubbing<String, ActorLocalBox, ActorTestFailure>()
    stubs.matching(.equal("respond")).willAnswer { _ async throws(ActorTestFailure) in
        await Task.yield()
        response.value = "second"
        return response
    }
    stubs.matching(.equal("offline")).willThrow(.offline)
    let endpoint = MainActorAsyncThrowingEndpoint(id: EndpointID("actor-async"),
                                                  configuration: stubs.finish(),
                                                  failureReporter: FailureReporter { _ in })

    let returned = try await endpoint.invoke("respond")
    #expect(returned === response)
    #expect(returned.value == "second")
    do {
        _ = try await endpoint.invoke("offline")
        Issue.record("Expected ActorTestFailure.offline")
    } catch {
        #expect(error == .offline)
    }
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(2)).passed)
    #expect(endpoint.verification(matching: .equal("offline"), phase: .threw).wasCalled(.once).passed)
}

@Test @MainActor func RUN026_mainActorVerificationUsesStableSnapshotAcrossReentry() {
    let setup = MainActorSyncStubbing<String, String>()
    setup.matching(.any).willAnswer { $0 }
    let endpoint = MainActorSyncEndpoint(id: EndpointID("actor-snapshot"),
                                         configuration: setup.finish(),
                                         failureReporter: FailureReporter { _ in })
    _ = endpoint.invoke("initial")
    let reentrant = MainActorMatcher<String> { value in
        _ = endpoint.invoke("nested")
        return value == "initial"
    }
    let result = endpoint.verification(matching: reentrant).wasCalled(.once)
    #expect(result.watermark == 1)
    #expect(result.invocationIDs == [1])
    #expect(result.passed)
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(2)).passed)
}
