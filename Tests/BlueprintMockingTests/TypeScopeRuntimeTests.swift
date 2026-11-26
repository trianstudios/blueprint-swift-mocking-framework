import Testing
@testable import BlueprintMocking

@Test func GEN025_boundScopeRejectsNewEpochAndKeepsVerificationStale() throws {
    let session = MockSession()
    let scope = session.makeEpochBoundMock()
    let previousEpoch = session.snapshot().epoch
    let issues = CriticalState<[MockIssue]>([])
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willReturn("configured")
    let endpoint = SyncEndpoint(
        id: EndpointID("type.title"), configuration: stubs.finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue) } },
        scope: scope, fallback: { _ in "fallback" }
    )
    #expect(endpoint.invoke("first") == "configured")
    _ = try session.resetHistory()
    #expect(endpoint.invoke("stale") == "fallback")
    #expect(session.snapshot().events.isEmpty)
    #expect(issues.withLock { $0.first?.message.contains("stale type-level mock scope") } == true)

    let result = endpoint.verification(matching: .any).wasCalled(.never)
    #expect(result.isStale)
    #expect(result.epoch == previousEpoch)
    #expect(!result.passed)
    #expect(issues.withLock { $0.last?.message.contains("Create a new scope") } == true)
}

@Test func GEN025_validBoundScopePreservesFinishedPolicy() throws {
    let session = MockSession()
    let received = CriticalState<String?>(nil)
    let endpoint = SyncEndpoint(
        id: EndpointID("type.title"), configuration: SyncStubbing<String, String>().finish(),
        failureReporter: FailureReporter { issue in received.withLock { $0 = issue.message } },
        scope: session.makeEpochBoundMock(), fallback: { _ in "fallback" }
    )
    try session.finishIfQuiescent()
    #expect(endpoint.invoke("finished") == "fallback")
    #expect(session.snapshot().events.isEmpty)
    #expect(received.withLock { $0 } == "Cannot call type.title in a finished mock session")
}

@Test func GEN025_staleScopeStillSettlesAnOldActiveInvocation() throws {
    let session = MockSession()
    let oldEpoch = session.snapshot().epoch
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { value in
        _ = try! session.resetHistory(.detachActive)
        return value
    }
    let endpoint = SyncEndpoint(
        id: EndpointID("type.inFlight"), configuration: stubs.finish(),
        failureReporter: FailureReporter { _ in }, scope: session.makeEpochBoundMock(), fallback: { _ in "fallback" }
    )
    #expect(endpoint.invoke("admitted") == "admitted")
    let old = try #require(session.snapshot(epoch: oldEpoch))
    #expect(old.events.map(\.phase) == [.admitted, .returned])
    #expect(endpoint.invoke("stale") == "fallback")
    #expect(session.snapshot().events.isEmpty)
}

@Test func GEN025_missingTypeScopeReturnsAndEmitsItsDiagnostic() {
    let message = BlueprintRuntimeSchemaV1.reportMissingTypeScope(
        EndpointID("type.title.get"),
        source: SourceLocation(fileID: "Domain/TypeDirectory.swift", filePath: "TypeDirectory.swift", line: 17, column: 2)
    )
    #expect(message == "Missing type-level mock scope for type.title.get")
}
