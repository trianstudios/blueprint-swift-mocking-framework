import BlueprintMocking
import Testing

private final class EffectPayload {
    var text: String

    init(_ text: String) {
        self.text = text
    }
}

private enum EffectFailure: Error { case offline }

@Test @MainActor func GEN013_mainActorSynchronousThrowingKeepsLocalValuesAndTypedFailure() throws {
    let request = EffectPayload("loaded")
    let response = EffectPayload("")
    let issues = Issues()
    let stubs = MainActorSyncThrowingStubbing<EffectPayload, EffectPayload, EffectFailure>()
    stubs.matching(.any).willThrow(.offline)
    stubs.matching(MainActorMatcher { $0 === request }).willAnswer { input throws(EffectFailure) in
        response.text += input.text
        return response
    }
    let endpoint = MainActorSyncThrowingEndpoint(id: EndpointID("actor-sync-throws"),
                                                 configuration: stubs.finish(),
                                                 failureReporter: issues.reporter)
    let actual = try endpoint.invoke(request)
    #expect(actual === response)
    #expect(response.text == "loaded")
    do {
        _ = try endpoint.invoke(EffectPayload("error"))
        Issue.record("Expected typed failure")
    } catch {
        #expect(error == .offline)
    }
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.once).passed)
    #expect(endpoint.verification(matching: .any, phase: .threw).wasCalled(.once).passed)
    #expect(issues.values.isEmpty)
}

@Test @MainActor func GEN013_mainActorAsynchronousNonthrowingStaysIsolatedAcrossSuspension() async {
    let request = EffectPayload("loaded")
    let response = EffectPayload("")
    let issues = Issues()
    let (entries, entered) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let stubs = MainActorAsyncStubbing<EffectPayload, EffectPayload>()
    stubs.matching(.any).willAnswer { input in
        entered.yield(())
        entered.finish()
        var gate = releases.makeAsyncIterator()
        _ = await gate.next()
        response.text += input.text
        return response
    }
    let endpoint = MainActorAsyncEndpoint(id: EndpointID("actor-async-nonthrowing"),
                                          configuration: stubs.finish(),
                                          failureReporter: issues.reporter)
    let invocation = Task { @MainActor in
        let actual = await endpoint.invoke(request)
        #expect(actual === response)
    }
    var entry = entries.makeAsyncIterator()
    _ = await entry.next()
    #expect(endpoint.verification(matching: .any).wasCalled(.once).passed)
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.never).passed)
    release.yield(())
    release.finish()
    await invocation.value
    #expect(response.text == "loaded")
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.once).passed)
    #expect(endpoint.invocations.first?.input === request)
    #expect(issues.values.isEmpty)
}

@Test @MainActor func RUN039_mainActorOrdinaryThrowingReportsBeforeThrowing() async {
    let issues = Issues()
    let syncSetup = MainActorSyncThrowingStubbing<EffectPayload, EffectPayload, any Error>()
    let sync = MainActorSyncThrowingEndpoint(id: EndpointID("actor-missing-sync"),
                                             configuration: syncSetup.finish(),
                                             failureReporter: issues.reporter)
    do {
        _ = try sync.invoke(EffectPayload("unstubbed"))
        Issue.record("Expected unexpected invocation error")
    } catch let error as UnexpectedInvocationError {
        #expect(error.issue.endpoint == EndpointID("actor-missing-sync"))
        #expect(issues.values.count == 1)
    } catch {
        Issue.record("Expected UnexpectedInvocationError, got \(error)")
    }
    let asyncSetup = MainActorAsyncThrowingStubbing<EffectPayload, EffectPayload, any Error>()
    let async = MainActorAsyncThrowingEndpoint(id: EndpointID("actor-missing-async"),
                                               configuration: asyncSetup.finish(),
                                               failureReporter: issues.reporter)
    do {
        _ = try await async.invoke(EffectPayload("unstubbed"))
        Issue.record("Expected unexpected invocation error")
    } catch let error as UnexpectedInvocationError {
        #expect(error.issue.endpoint == EndpointID("actor-missing-async"))
        #expect(issues.values.count == 2)
    } catch {
        Issue.record("Expected UnexpectedInvocationError, got \(error)")
    }
    #expect(sync.invocations.map(\.phase) == [.threw])
    #expect(async.invocations.map(\.phase) == [.threw])
}

@Test @MainActor func RUN039_mainActorFallbackReportsFirstAndReturnsLocalValue() async {
    let fallback = EffectPayload("")
    let issues = Issues()
    let syncSetup = MainActorSyncStubbing<EffectPayload, EffectPayload>()
    let sync = MainActorSyncEndpoint(id: EndpointID("actor-sync-fallback"),
                                     configuration: syncSetup.finish(),
                                     failureReporter: issues.reporter, fallback: { issue in
        #expect(issues.values.first?.endpoint == issue.endpoint)
        fallback.text += "sync "
        return fallback
    })
    let actual = sync.invoke(EffectPayload("unstubbed"))
    #expect(actual === fallback)
    let asyncSetup = MainActorAsyncStubbing<EffectPayload, EffectPayload>()
    let async = MainActorAsyncEndpoint(id: EndpointID("actor-async-fallback"),
                                       configuration: asyncSetup.finish(),
                                       failureReporter: issues.reporter, fallback: { issue in
        #expect(issues.values.last?.endpoint == issue.endpoint)
        fallback.text += "async"
        return fallback
    })
    let asyncResult = await async.invoke(EffectPayload("unstubbed"))
    #expect(asyncResult === fallback)
    #expect(fallback.text == "sync async")
    #expect(issues.values.count == 2)
    #expect(sync.invocations.map(\.phase) == [.returned])
    #expect(async.invocations.map(\.phase) == [.returned])
}
