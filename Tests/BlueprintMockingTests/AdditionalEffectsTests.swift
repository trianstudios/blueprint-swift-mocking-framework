import Testing
@testable import BlueprintMocking

@Test func GEN013_syncThrowingAnswersKeepTypedFailuresAndHistory() throws {
    let issues = Issues()
    let stubs = SyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value throws(ServiceError) in value.uppercased() }
    // Install specific rules last so they beat the wildcard answer.
    stubs.matching(.equal("return")).willReturn("Ada")
    stubs.matching(.equal("throw")).willThrow(.offline)
    let endpoint = SyncThrowingEndpoint(id: EndpointID("typed"), configuration: stubs.finish(),
                                        failureReporter: issues.reporter)
    #expect(try endpoint.invoke("return") == "Ada")
    #expect(try endpoint.invoke("answer") == "ANSWER")
    do {
        _ = try endpoint.invoke("throw")
        Issue.record("Expected a typed error")
    } catch {
        #expect(error == .offline)
    }
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(endpoint.verification(matching: .equal("throw"), phase: .threw).wasCalled(.once).passed)
    #expect(issues.values.isEmpty)
}

@Test func RUN039_unstubbedOrdinaryThrowingCallsReportBeforeThrowing() async {
    let issues = Issues()
    let syncStubs = SyncThrowingStubbing<String, String, any Error>()
    let sync = SyncThrowingEndpoint(id: EndpointID("sync-missing"), configuration: syncStubs.finish(),
                                    failureReporter: issues.reporter)
    do {
        _ = try sync.invoke("missing")
        Issue.record("Expected an unstubbed invocation error")
    } catch let error as UnexpectedInvocationError {
        #expect(issues.values.count == 1)
        #expect(issues.values.first?.endpoint == error.issue.endpoint)
        #expect(error.issue.endpoint == EndpointID("sync-missing"))
        #expect(error.issue.kind == .unexpectedCall)
    } catch {
        Issue.record("Expected UnexpectedInvocationError, got \(error)")
    }

    let asyncStubs = AsyncThrowingStubbing<String, String, any Error>()
    let async = AsyncThrowingEndpoint(id: EndpointID("async-missing"), configuration: asyncStubs.finish(),
                                     failureReporter: issues.reporter)
    do {
        _ = try await async.invoke("missing")
        Issue.record("Expected an unstubbed invocation error")
    } catch let error as UnexpectedInvocationError {
        #expect(issues.values.count == 2)
        #expect(issues.values.last?.endpoint == error.issue.endpoint)
        #expect(error.issue.endpoint == EndpointID("async-missing"))
    } catch {
        Issue.record("Expected UnexpectedInvocationError, got \(error)")
    }

    #expect(sync.invocations.map(\.phase) == [.threw])
    #expect(async.invocations.map(\.phase) == [.threw])
}

@Test func GEN013_asyncNonthrowingAnswersRetainAsynchronousCalls() async {
    let issues = Issues()
    let stubs = AsyncStubbing<String, String>()
    let (entrySignal, entered) = AsyncStream<Void>.makeStream()
    let (releaseSignal, release) = AsyncStream<Void>.makeStream()
    stubs.matching(.any).willAnswer { value in
        entered.yield(())
        entered.finish()
        var signal = releaseSignal.makeAsyncIterator()
        _ = await signal.next()
        return value.uppercased()
    }
    stubs.matching(.equal("return")).willReturn("Ada")
    let endpoint = AsyncEndpoint(id: EndpointID("nonthrowing"), configuration: stubs.finish(),
                                 failureReporter: issues.reporter)
    #expect(endpoint.verification(matching: .any).wasCalled(.never).passed)
    #expect(await endpoint.invoke("return") == "Ada")
    let request = Task { await endpoint.invoke("answer") }
    var signal = entrySignal.makeAsyncIterator()
    _ = await signal.next()
    #expect(endpoint.verification(matching: .equal("answer")).wasCalled(.once).passed)
    #expect(endpoint.verification(matching: .equal("answer"), phase: .returned).wasCalled(.never).passed)
    release.yield(())
    release.finish()
    #expect(await request.value == "ANSWER")
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(endpoint.invocations.map(\.input) == ["return", "answer"])
    #expect(issues.values.isEmpty)
}
