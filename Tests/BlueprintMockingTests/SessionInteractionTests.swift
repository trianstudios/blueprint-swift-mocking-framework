import Testing
import BlueprintMocking

private func interactionEndpoint(_ name: String, scope: MockScope, issues: Issues)
    -> SyncEndpoint<String, String> {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    return SyncEndpoint(id: EndpointID(name), configuration: stubs.finish(),
                        failureReporter: issues.reporter, scope: scope)
}

@Test func RUN028_noInteractionsHasAnExplicitDomainAndSnapshotWatermark() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let untouchedScope = session.makeMock()
    let issues = Issues()
    let endpoint = interactionEndpoint("lookup", scope: scope, issues: issues)
    let empty = session.snapshot()
    let expectedEmpty = try empty.verifyNoInteractions(in: .session)
    #expect(expectedEmpty.passed)
    #expect(expectedEmpty.outcome == .noInteractions)
    #expect(expectedEmpty.epoch == empty.epoch)
    #expect(expectedEmpty.watermark == empty.watermark)

    _ = endpoint.invoke("value")
    #expect(try empty.verifyNoInteractions(in: .session).passed)
    let observed = try session.verifyNoInteractions(in: .session)
    let snapshot = session.snapshot()
    let admission = try #require(snapshot.events.first)
    #expect(observed.outcome == .interaction(admission))
    #expect(!observed.passed)
    #expect(observed.watermark == snapshot.watermark)
    #expect(try session.verifyNoInteractions(in: .mock(scope.id)).outcome == .interaction(admission))
    #expect(try session.verifyNoInteractions(in: .mock(untouchedScope.id)).passed)
    #expect(issues.values.isEmpty)
}

@Test func RUN028_noInteractionsIncludesAnInFlightAdmission() async throws {
    let session = MockSession()
    let issues = Issues()
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value async throws(ServiceError) in
        entered.continuation.finish()
        for await _ in release.stream {}
        return value
    }
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("pending"), configuration: stubs.finish(),
                                         failureReporter: issues.reporter, scope: session.makeMock())

    let task = Task { try await endpoint.invoke("value") }
    for await _ in entered.stream {}
    let inFlight = session.snapshot()
    let admission = try #require(inFlight.events.first)
    #expect(inFlight.activeInvocationCount == 1)
    #expect(admission.phase == .admitted)
    #expect(try inFlight.verifyNoInteractions(in: .session).outcome == .interaction(admission))
    let checkpoint = session.checkpoint()
    release.continuation.finish()
    #expect(try await task.value == "value")
    // A completion after the checkpoint does not constitute another admission.
    #expect(try session.verifyNoInteractions(in: .session, since: checkpoint).passed)
    #expect(try session.verifyNoInteractions(in: .session).outcome == .interaction(admission))
    #expect(issues.values.isEmpty)
}

@Test func RUN028_ignoredEndpointsMatchBothMockAndEndpointIdentity() throws {
    let session = MockSession()
    let first = session.makeMock()
    let second = session.makeMock()
    let issues = Issues()
    let firstEndpoint = interactionEndpoint("lookup", scope: first, issues: issues)
    let secondEndpoint = interactionEndpoint("lookup", scope: second, issues: issues)
    let ignored = SessionCallSelector(mockID: first.id, endpoint: EndpointID("lookup"))

    _ = firstEndpoint.invoke("ignore")
    #expect(try session.verifyNoInteractions(in: .session, ignoring: [ignored]).passed)
    _ = secondEndpoint.invoke("report")
    let visible = try #require(session.snapshot().events.last(where: { $0.phase == .admitted }))
    #expect(try session.verifyNoInteractions(in: .session, ignoring: [ignored]).outcome == .interaction(visible))
    #expect(try session.verifyNoInteractions(in: .mock(first.id), ignoring: [ignored]).passed)
    #expect(issues.values.isEmpty)
}

@Test func RUN028_pruningCannotProveAbsenceButRetainedAdmissionsCanDisproveIt() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let noCallsScope = session.makeMock()
    let issues = Issues()
    let endpoint = interactionEndpoint("lookup", scope: scope, issues: issues)
    let initial = session.checkpoint()
    _ = endpoint.invoke("will be pruned")
    let through = session.checkpoint()
    try session.discardEvents(through: through)

    #expect(try session.verifyNoInteractions(in: .session).outcome == .historyUnavailable)
    let unknown = try session.verifyNoInteractions(in: .mock(noCallsScope.id), since: initial)
    #expect(unknown.outcome == .historyUnavailable)
    #expect(!unknown.passed)
    #expect(try session.verifyNoInteractions(in: .session, since: through).passed)

    _ = endpoint.invoke("retained")
    let admission = try #require(session.snapshot().events.first)
    #expect(try session.verifyNoInteractions(in: .session).outcome == .interaction(admission))
    #expect(try session.verifyNoInteractions(in: .session, since: through).outcome == .interaction(admission))
    #expect(issues.values.isEmpty)
}

@Test func RUN028_noInteractionsRejectsForeignStaleAndInvertedWindows() throws {
    let session = MockSession()
    let foreign = MockSession()
    let foreignScope = foreign.makeMock()
    let ignored = SessionCallSelector(mockID: foreignScope.id, endpoint: EndpointID("lookup"))
    #expect(try session.verifyNoInteractions(in: .mock(foreignScope.id)).outcome == .foreignMock(foreignScope.id))
    #expect(try session.verifyNoInteractions(in: .session, ignoring: [ignored]).outcome == .foreignMock(foreignScope.id))
    do {
        _ = try session.verifyNoInteractions(in: .session, since: foreign.checkpoint())
        Issue.record("Expected a foreign checkpoint error")
    } catch {
        #expect(error == .foreignSession)
    }

    let original = session.checkpoint()
    _ = try session.resetHistory()
    do {
        _ = try session.verifyNoInteractions(in: .session, since: original)
        Issue.record("Expected a stale checkpoint error")
    } catch {
        #expect(error == .staleEpoch)
    }

    let prior = session.snapshot()
    let issues = Issues()
    let endpoint = interactionEndpoint("lookup", scope: session.makeMock(), issues: issues)
    _ = endpoint.invoke("later")
    let inverted = try prior.verifyNoInteractions(in: .session, since: session.checkpoint())
    #expect(inverted.outcome == .checkpointAfterSnapshot)
    #expect(!inverted.passed)
    #expect(inverted.watermark == prior.watermark)
    #expect(issues.values.isEmpty)
}
