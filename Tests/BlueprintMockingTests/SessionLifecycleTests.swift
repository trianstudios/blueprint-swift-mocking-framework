import Testing
@testable import BlueprintMocking

@Test func RUN034_activeResetAndLateCompletionRespectSessionEpochs() async throws {
    let issues = Issues()
    let session = MockSession()
    let scope = session.makeMock()
    let member = EndpointID("session-load")
    let initialEpoch = session.snapshot().epoch
    let (entries, enter) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (releases, release) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { release.finish() }

    let setup = AsyncThrowingStubbing<String, String, ServiceError>()
    setup.matching(.equal("pending")).willAnswer { _ in
        enter.yield(true)
        var gate = releases.makeAsyncIterator()
        _ = await gate.next()
        return "admitted answer"
    }
    let endpoint = AsyncThrowingEndpoint(
        id: member, configuration: setup.finish(), failureReporter: issues.reporter, scope: scope
    )
    let originalVerification = endpoint.verification(matching: .equal("pending"))
    let oldCall = Task {
        defer { enter.finish() }
        return try await endpoint.invoke("pending")
    }
    var admissions = entries.makeAsyncIterator()
    let entered = await admissions.next()
    try #require(entered == true)

    let beforeReset = session.snapshot()
    #expect(beforeReset.epoch == initialEpoch)
    #expect(beforeReset.activeInvocationCount == 1)
    let beforeResetAdmission = try #require(beforeReset.events.first)
    #expect(beforeResetAdmission.phase == .admitted)
    #expect(beforeResetAdmission.mockID == scope.id)
    #expect(beforeResetAdmission.endpoint == member)
    #expect(beforeResetAdmission.configurationRevision.rawValue == 0)
    #expect(originalVerification.wasCalled(.once).passed)

    do {
        _ = try session.resetHistory()
        Issue.record("Expected an active invocation to prevent a quiescent reset")
    } catch {
        guard case .activeInvocations(count: 1) = error else {
            Issue.record("Expected an active reset error for the suspended call")
            return
        }
    }
    #expect(session.snapshot().epoch == initialEpoch)
    #expect(session.snapshot().activeInvocationCount == 1)

    let currentEpoch = try session.resetHistory(.detachActive)
    #expect(currentEpoch != initialEpoch)
    let afterReset = session.snapshot()
    #expect(afterReset.epoch == currentEpoch)
    #expect(afterReset.activeInvocationCount == 0)
    #expect(afterReset.events.isEmpty)
    let stale = originalVerification.wasCalled(.never)
    #expect(stale.isStale)
    #expect(!stale.passed)
    #expect(endpoint.verification(matching: .any).wasCalled(.never).passed)

    let replacement = AsyncThrowingStubbing<String, String, ServiceError>()
    replacement.matching(.equal("new")).willReturn("replacement answer")
    let revision = endpoint.replaceConfiguration(replacement.finish())
    #expect(try await endpoint.invoke("new") == "replacement answer")

    release.finish()
    #expect(try await oldCall.value == "admitted answer")
    let previous = try #require(session.snapshot(epoch: initialEpoch))
    let current = try #require(session.snapshot(epoch: currentEpoch))
    #expect(previous.activeInvocationCount == 0)
    #expect(current.activeInvocationCount == 0)
    #expect(previous.events.map(\.phase) == [.admitted, .returned])
    #expect(current.events.map(\.phase) == [.admitted, .returned])
    #expect(previous.events.allSatisfy { $0.invocationID == beforeResetAdmission.invocationID })
    #expect(previous.events.allSatisfy { $0.configurationRevision == beforeResetAdmission.configurationRevision })
    #expect(current.events.allSatisfy { $0.invocationID != beforeResetAdmission.invocationID })
    #expect(current.events.allSatisfy { $0.configurationRevision == revision })
    let oldCompletion = try #require(previous.events.last)
    let newCompletion = try #require(current.events.last)
    #expect(oldCompletion.ordinal > newCompletion.ordinal)
    #expect(endpoint.verification(matching: .equal("pending")).wasCalled(.never).passed)
    #expect(endpoint.verification(matching: .equal("new"), phase: .returned).wasCalled(.once).passed)
}

@Test func RUN037_epochsBelongToTheSessionThatCreatedThem() {
    let first = MockSession()
    let second = MockSession()
    let firstEpoch = first.snapshot().epoch
    let secondEpoch = second.snapshot().epoch

    #expect(first.id != second.id)
    #expect(firstEpoch != secondEpoch)
    #expect(first.snapshot(epoch: firstEpoch) != nil)
    #expect(second.snapshot(epoch: firstEpoch) == nil)
    #expect(first.snapshot(epoch: secondEpoch) == nil)
}

private final class ResetProbe: Sendable {
    let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@Test func RUN042_quiescentResetReleasesHistoryOutsideTheSessionLock() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let issues = Issues()
    let setup = SyncStubbing<ResetProbe, Int>()
    setup.matching(.any).willReturn(1)
    let endpoint = SyncEndpoint(
        id: EndpointID("retained-input"), configuration: setup.finish(),
        failureReporter: issues.reporter, scope: scope
    )
    let releases = CriticalState<[SessionEpoch]>([])
    #expect(endpoint.invoke(ResetProbe {
        let epoch = session.snapshot().epoch
        releases.withLock { $0.append(epoch) }
    }) == 1)
    #expect(releases.withLock { $0 }.isEmpty)

    let initialEpoch = session.snapshot().epoch
    let newEpoch = try session.resetHistory()
    #expect(releases.withLock { $0 } == [newEpoch])
    #expect(session.snapshot(epoch: initialEpoch) == nil)
    #expect(endpoint.invocations.isEmpty)
}

@Test func RUN036_reentrantAnswersShareOneOrderedSessionTimeline() {
    let session = MockSession()
    let issues = Issues()
    let innerRules = SyncStubbing<String, String>()
    innerRules.matching(.any).willReturn("inner result")
    let inner = SyncEndpoint(id: EndpointID("inner"), configuration: innerRules.finish(),
                             failureReporter: issues.reporter, scope: session.makeMock())
    let outerRules = SyncStubbing<String, String>()
    outerRules.matching(.any).willAnswer { inner.invoke($0) }
    let outer = SyncEndpoint(id: EndpointID("outer"), configuration: outerRules.finish(),
                             failureReporter: issues.reporter, scope: session.makeMock())

    #expect(outer.invoke("input") == "inner result")
    let snapshot = session.snapshot()
    #expect(snapshot.activeInvocationCount == 0)
    let events = snapshot.events
    #expect(events.map(\.endpoint.rawValue) == ["outer", "inner", "inner", "outer"])
    #expect(events.map(\.phase) == [.admitted, .admitted, .returned, .returned])
    #expect(events.first?.invocationID == events.last?.invocationID)
}

@Test func RUN035_failureMappingRemainsActiveUntilItsErrorIsProduced() {
    let session = MockSession()
    let issues = Issues()
    let setup = SyncThrowingStubbing<String, String, ServiceError>()
    let endpoint = SyncThrowingEndpoint(
        id: EndpointID("mapped-failure"), configuration: setup.finish(),
        failureReporter: issues.reporter, scope: session.makeMock(),
        failureMapping: { _ in
            #expect(session.snapshot().activeInvocationCount == 1)
            #expect(throws: SessionResetError.activeInvocations(count: 1)) {
                try session.resetHistory()
            }
            return .offline
        }
    )
    #expect(throws: ServiceError.offline) { try endpoint.invoke("unstubbed") }
    #expect(issues.values.count == 1)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .threw])
}
