import Testing
import BlueprintMocking

@Test func RUN036_checkpointReturnsOrderedSuffixAcrossMocks() throws {
    let session = MockSession()
    let firstScope = session.makeMock()
    let secondScope = session.makeMock()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let configuration = stubs.finish()
    let issues = Issues()
    let first = SyncEndpoint(id: EndpointID("first"), configuration: configuration,
                             failureReporter: issues.reporter, scope: firstScope)
    let second = SyncEndpoint(id: EndpointID("second"), configuration: configuration,
                              failureReporter: issues.reporter, scope: secondScope)

    #expect(first.invoke("before") == "before")
    let checkpoint = session.checkpoint()
    #expect(checkpoint.sessionID == session.id)
    #expect(checkpoint.epoch == session.snapshot().epoch)
    #expect(checkpoint.watermark == session.snapshot().watermark)
    #expect(try session.events(since: checkpoint).isEmpty)

    #expect(second.invoke("after") == "after")
    #expect(first.invoke("again") == "again")

    let suffix = try session.events(since: checkpoint)
    #expect(suffix.map(\.mockID) == [secondScope.id, secondScope.id, firstScope.id, firstScope.id])
    #expect(suffix.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    let ordinals = suffix.map(\.ordinal)
    #expect(ordinals == ordinals.sorted())
    #expect(Set(ordinals).count == 4)
    #expect(ordinals.allSatisfy { $0 > checkpoint.watermark })
    #expect(try session.events(since: checkpoint).map(\.ordinal) == ordinals)
    #expect(try session.events(since: session.checkpoint()).isEmpty)
    #expect(issues.values.isEmpty)
}

@Test func RUN036_checkpointIncludesCompletionOfAlreadyAdmittedCall() async throws {
    let session = MockSession()
    let admitted = AsyncStream<Void>.makeStream()
    let resumeAnswer = AsyncStream<Void>.makeStream()
    defer { resumeAnswer.continuation.finish() }
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value async throws(ServiceError) in
        admitted.continuation.finish()
        for await _ in resumeAnswer.stream {}
        return value
    }
    let issues = Issues()
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("suspended"), configuration: stubs.finish(),
                                         failureReporter: issues.reporter, scope: session.makeMock())

    let invocation = Task { try await endpoint.invoke("value") }
    for await _ in admitted.stream {}
    let admission = try #require(session.snapshot().events.first)
    let checkpoint = session.checkpoint()
    #expect(admission.phase == .admitted)
    #expect(checkpoint.watermark == admission.ordinal)
    #expect(try session.events(since: checkpoint).isEmpty)

    resumeAnswer.continuation.finish()
    #expect(try await invocation.value == "value")
    let suffix = try session.events(since: checkpoint)
    #expect(suffix.count == 1)
    let completion = try #require(suffix.first)
    #expect(completion.phase == .returned)
    #expect(completion.invocationID == admission.invocationID)
    #expect(completion.ordinal > checkpoint.watermark)
    #expect(issues.values.isEmpty)
}

@Test func RUN034_checkpointDoesNotRetargetToAnotherSession() {
    let origin = MockSession()
    let other = MockSession()
    let checkpoint = origin.checkpoint()
    #expect(other.checkpoint().epoch.rawValue == checkpoint.epoch.rawValue)
    #expect(other.checkpoint().watermark == checkpoint.watermark)
    do {
        _ = try other.events(since: checkpoint)
        Issue.record("Expected a foreign-session checkpoint error")
    } catch {
        #expect(error == .foreignSession)
    }
}

@Test(arguments: [SessionResetMode.requireQuiescence, .detachActive])
func RUN034_checkpointRetainsItsEpochAcrossReset(_ mode: SessionResetMode) throws {
    let session = MockSession()
    let beforeReset = session.checkpoint()
    let currentEpoch = try session.resetHistory(mode)
    let afterReset = session.checkpoint()
    #expect(afterReset.epoch == currentEpoch)
    #expect(afterReset.epoch != beforeReset.epoch)
    #expect(afterReset.sessionID == beforeReset.sessionID)
    #expect(try session.events(since: afterReset).isEmpty)

    do {
        _ = try session.events(since: beforeReset)
        Issue.record("Expected a stale-epoch checkpoint error")
    } catch {
        #expect(error == .staleEpoch)
    }
}
