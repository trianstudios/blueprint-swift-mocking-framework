import Testing
@testable import BlueprintMocking

@Test func DX026_finishRejectsActiveCallsAndFreezesFinalSnapshot() async throws {
    let session = MockSession()
    let issues = Issues()
    let (entries, enter) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (releases, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }

    let setup = AsyncStubbing<String, String>()
    setup.matching(.any).willAnswer { value in
        enter.yield(true)
        var gate = releases.makeAsyncIterator()
        _ = await gate.next()
        return value
    }
    let held = AsyncEndpoint(
        id: EndpointID("held"), configuration: setup.finish(),
        failureReporter: issues.reporter, scope: session.makeMock()
    )
    let running = Task {
        defer { enter.finish() }
        return await held.invoke("completed")
    }
    var admissions = entries.makeAsyncIterator()
    let entered = await admissions.next()
    try #require(entered == true)
    #expect(session.snapshot().activeInvocationCount == 1)

    #expect(throws: SessionFinishError.activeInvocations(count: 1)) {
        try session.finishIfQuiescent()
    }
    #expect(!session.snapshot().isFinished)
    #expect(session.snapshot().events.map(\.phase) == [.admitted])

    release.finish()
    #expect(await running.value == "completed")
    let beforeFinish = session.snapshot()
    let finished = try session.finishIfQuiescent()
    #expect(finished.isFinished)
    #expect(finished.activeInvocationCount == 0)
    #expect(finished.epoch == beforeFinish.epoch)
    #expect(finished.events == beforeFinish.events)
    #expect(finished.events.map(\.phase) == [.admitted, .returned])
    #expect(finished.watermark == beforeFinish.watermark)
    #expect(try session.finishIfQuiescent() == finished)
    #expect(session.snapshot() == finished)
    #expect(throws: SessionResetError.finished) { try session.resetHistory() }
    #expect(throws: SessionResetError.finished) { try session.resetHistory(.detachActive) }
    #expect(session.snapshot() == finished)
    #expect(issues.values.isEmpty)
}

@Test func DX026_lateCallsReportWithoutRunningStubsOrAppendingHistory() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let issues = Issues()
    let executions = CriticalState(0)
    let syncID = EndpointID("nonthrowing")
    let throwingID = EndpointID("ordinary throwing")
    let syncSetup = SyncStubbing<String, Int>()
    syncSetup.matching(.any).willAnswer { _ in
        executions.withLock { $0 += 1 }
        return 42
    }
    let sync = SyncEndpoint(
        id: syncID, configuration: syncSetup.finish(), failureReporter: issues.reporter,
        scope: scope, fallback: { issue in
            #expect(issues.values.last?.endpoint == issue.endpoint)
            #expect(session.snapshot().isFinished)
            return -1
        }
    )
    let throwingSetup = SyncThrowingStubbing<String, Int, any Error>()
    throwingSetup.matching(.any).willAnswer { _ in
        executions.withLock { $0 += 1 }
        return 7
    }
    let ordinary = SyncThrowingEndpoint(
        id: throwingID, configuration: throwingSetup.finish(),
        failureReporter: issues.reporter, scope: scope
    )

    #expect(sync.invoke("before") == 42)
    #expect(try ordinary.invoke("before") == 7)
    let finished = try session.finishIfQuiescent()

    #expect(sync.invoke("after") == -1)
    do {
        _ = try ordinary.invoke("after")
        Issue.record("Expected a late ordinary call to throw")
    } catch let error as UnexpectedInvocationError {
        #expect(error.issue.endpoint == throwingID)
        #expect(issues.values.last?.endpoint == error.issue.endpoint)
    } catch {
        Issue.record("Expected UnexpectedInvocationError, got \(error)")
    }
    #expect(issues.values.map(\.endpoint) == [syncID, throwingID])
    #expect(executions.withLock { $0 } == 2)
    #expect(session.snapshot() == finished)
    #expect(sync.invocations.map(\.input) == ["before"])
    #expect(ordinary.invocations.map(\.input) == ["before"])
}

@Test func DX026_finishedSessionsRejectContextResolutionAndRebinding() throws {
    let session = MockSession()
    let handle = session.contextHandle

    try session.withContext { () throws(SessionFinishError) in
        #expect((try? session.requireCurrentContext()) == handle)
        _ = try session.finishIfQuiescent()
        #expect(throws: MockSessionContextError.finishedSession) { try session.requireCurrentContext() }
    }
    #expect(throws: MockSessionContextError.finishedSession) {
        try session.withContext(handle) {
            Issue.record("A finished session allowed its context to be rebound")
        }
    }
}
