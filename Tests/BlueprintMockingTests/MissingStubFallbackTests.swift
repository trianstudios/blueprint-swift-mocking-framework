import Testing
@testable import BlueprintMocking

@Test func RUN039_unstubbedVoidCallsReportAndReturn() async {
    let issues = Issues()
    let syncStubs = SyncStubbing<String, Void>()
    syncStubs.matching(.equal("stubbed")).willReturn(())
    let sync = SyncEndpoint(id: EndpointID("void-sync"), configuration: syncStubs.finish(),
                            failureReporter: issues.reporter, fallback: { _ in () })
    let asyncStubs = AsyncStubbing<String, Void>()
    asyncStubs.matching(.equal("stubbed")).willAnswer { _ in }
    let async = AsyncEndpoint(id: EndpointID("void-async"), configuration: asyncStubs.finish(),
                              failureReporter: issues.reporter, fallback: { _ in () })

    sync.invoke("stubbed")
    await async.invoke("stubbed")
    #expect(issues.values.isEmpty)

    sync.invoke("unstubbed")
    await async.invoke("unstubbed")
    #expect(issues.values.count == 2)
    #expect(issues.values.map(\.kind) == [.unexpectedCall, .unexpectedCall])
    #expect(issues.values.map(\.endpoint.rawValue) == ["void-sync", "void-async"])
    #expect(issues.values.map(\.watermark) == [2, 2])
    #expect(sync.verification(matching: .equal("unstubbed"), phase: .returned).wasCalled(.once).passed)
    #expect(async.verification(matching: .equal("unstubbed"), phase: .returned).wasCalled(.once).passed)
}

@Test func RUN039_syncValueFallbackReportsBeforeReturningAndRunsOutsideTheJournalLock() {
    let issues = Issues()
    let duringFallback = CriticalState<Verification<String>?>(nil)
    let stubs = SyncStubbing<String, Int>()
    stubs.matching(.equal("stubbed")).willReturn(42)
    let endpoint = SyncEndpoint(id: EndpointID("sync-value"), configuration: stubs.finish(),
                                failureReporter: issues.reporter, fallback: { issue in
        #expect(issues.values.first?.watermark == issue.watermark)
        #expect(issues.values.count == 1)
        let query = duringFallback.withLock { $0 }
        #expect(query?.wasCalled(.never).passed == true)
        return -1
    })
    duringFallback.withLock {
        $0 = endpoint.verification(matching: .equal("unstubbed"), phase: .returned)
    }

    #expect(endpoint.invoke("stubbed") == 42)
    #expect(issues.values.isEmpty)
    #expect(endpoint.invoke("unstubbed") == -1)
    #expect(issues.values.count == 1)
    #expect(endpoint.verification(matching: .equal("unstubbed"), phase: .returned).wasCalled(.once).passed)
}

@Test func RUN039_asyncValueFallbackReceivesItsIssueAndCompletesTheCall() async {
    let issues = Issues()
    let stubs = AsyncStubbing<String, Int>()
    stubs.matching(.equal("stubbed")).willReturn(42)
    let location = SourceLocation(fileID: "Consumer/Source.swift", filePath: "Source.swift", line: 17)
    let endpoint = AsyncEndpoint(id: EndpointID("async-value"), configuration: stubs.finish(),
                                 failureReporter: issues.reporter, fallback: { issue in
        #expect(issue.endpoint == EndpointID("async-value"))
        #expect(issue.source == location)
        #expect(issues.values.first?.source == issue.source)
        #expect(issues.values.count == 1)
        return -2
    })
    #expect(await endpoint.invoke("stubbed") == 42)
    #expect(issues.values.isEmpty)
    #expect(await endpoint.invoke("unstubbed", source: location) == -2)
    #expect(endpoint.invocations.map(\.phase) == [.returned, .returned])
    #expect(issues.values.count == 1)
}
