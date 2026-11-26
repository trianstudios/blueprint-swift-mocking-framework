import Testing
import BlueprintMocking

private func completenessEndpoint(_ name: String, scope: MockScope) -> (
    endpoint: SyncEndpoint<String, String>, selector: SessionCallSelector
) {
    let id = EndpointID(name)
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(id: id, configuration: stubs.finish(),
                                failureReporter: FailureReporter { _ in }, scope: scope)
    return (endpoint, SessionCallSelector(mockID: scope.id, endpoint: id))
}

@Test func RUN028_consumedAdmissionsStillDisproveNoInteractions() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let (endpoint, selector) = completenessEndpoint("load", scope: scope)
    let covered = session.consumptionScope(named: "covered")
    let unclaimed = session.consumptionScope(named: "unclaimed")
    _ = endpoint.invoke("value")
    let final = try session.finishIfQuiescent()
    let admission = try #require(final.events.first)

    let asserted = try session.verifyNoMoreInteractions(in: .mock(scope.id), consumptionScope: covered)
    #expect(asserted.outcome == .interaction(admission))
    #expect(asserted.watermark == final.watermark)
    #expect(asserted.epoch == final.epoch)

    let claims = try session.consume(.all, for: selector, in: covered)
    #expect(claims.invocationIDs == [admission.invocationID])
    let sameNamedScope = session.consumptionScope(named: covered.name)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: sameNamedScope).passed)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: unclaimed)
        .outcome == .interaction(admission))
    #expect(try session.verifyNoInteractions(in: .session).outcome == .interaction(admission))
    #expect(session.snapshot() == final)
}

@Test func RUN028_noMoreInteractionsUsesExplicitSuffixAndMockDomain() throws {
    let session = MockSession()
    let initialMock = session.makeMock()
    let targetMock = session.makeMock()
    let (initial, _) = completenessEndpoint("lookup", scope: initialMock)
    let (target, targetSelector) = completenessEndpoint("lookup", scope: targetMock)
    let scope = session.consumptionScope(named: "target")
    _ = initial.invoke("before checkpoint")
    let checkpoint = session.checkpoint()
    _ = target.invoke("after checkpoint")
    let latest = session.snapshot()
    let recentAdmission = try #require(latest.events.last(where: { $0.phase == .admitted }))

    let remaining = try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope, since: checkpoint)
    #expect(remaining.outcome == .interaction(recentAdmission))
    #expect(remaining.watermark == latest.watermark)
    _ = try session.consume(.earliest(1), for: targetSelector, in: scope)

    #expect(try session.verifyNoMoreInteractions(in: .mock(targetMock.id), consumptionScope: scope).passed)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope, since: checkpoint).passed)
    let older = try #require(latest.events.first)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope)
        .outcome == .interaction(older))
}

@Test func RUN028_noMoreInteractionsRespectsExplicitIgnoredEndpoints() throws {
    let session = MockSession()
    let scope = session.makeMock()
    let other = session.makeMock()
    let (ignored, ignoredSelector) = completenessEndpoint("load", scope: scope)
    let (visible, visibleSelector) = completenessEndpoint("load", scope: other)
    let claims = session.consumptionScope(named: "checks")
    _ = ignored.invoke("ignored mock")
    _ = visible.invoke("same endpoint on another mock")
    let visibleAdmission = try #require(session.snapshot().events.last(where: { $0.phase == .admitted }))

    let remaining = try session.verifyNoMoreInteractions(
        in: .session, consumptionScope: claims, ignoring: [ignoredSelector])
    #expect(remaining.outcome == .interaction(visibleAdmission))
    _ = try session.consume(.all, for: visibleSelector, in: claims)
    #expect(try session.verifyNoMoreInteractions(
        in: .session, consumptionScope: claims, ignoring: [ignoredSelector]).passed)
    #expect(try session.verifyNoInteractions(in: .session, ignoring: [ignoredSelector])
        .outcome == .interaction(visibleAdmission))
}

@Test func RUN028_pruningCannotHideUnconsumedInteractions() throws {
    let session = MockSession()
    let (first, _) = completenessEndpoint("first", scope: session.makeMock())
    let (retained, retainedSelector) = completenessEndpoint("retained", scope: session.makeMock())
    let covered = session.consumptionScope(named: "retained only")
    let unclaimed = session.consumptionScope(named: "unclaimed")
    _ = first.invoke("unclaimed and pruned")
    let checkpoint = session.checkpoint()
    _ = retained.invoke("retained")
    _ = try session.consume(.all, for: retainedSelector, in: covered)
    let admission = try #require(session.snapshot().events.last(where: { $0.phase == .admitted }))
    try session.discardEvents(through: checkpoint)

    let notProven = try session.verifyNoMoreInteractions(in: .session, consumptionScope: covered)
    #expect(!notProven.passed)
    #expect(notProven.outcome == .historyUnavailable)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: covered, since: checkpoint).passed)
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: unclaimed)
        .outcome == .interaction(admission))
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: unclaimed, since: checkpoint)
        .outcome == .interaction(admission))
}

@Test func RUN028_noMoreInteractionsRejectsForeignAndStaleScopesAndCheckpoints() throws {
    let session = MockSession()
    let other = MockSession()
    let first = session.consumptionScope(named: "scope")
    let original = session.checkpoint()
    let foreignMock = other.makeMock()
    let foreignSelector = SessionCallSelector(mockID: foreignMock.id, endpoint: EndpointID("load"))

    #expect(throws: SessionConsumptionError.foreignSession) {
        try other.verifyNoMoreInteractions(in: .session, consumptionScope: first)
    }
    #expect(throws: SessionConsumptionError.foreignSession) {
        try session.verifyNoMoreInteractions(in: .session, consumptionScope: first, since: other.checkpoint())
    }
    let invalidDomain = try session.verifyNoMoreInteractions(in: .mock(foreignMock.id), consumptionScope: first)
    #expect(invalidDomain.outcome == .foreignMock(foreignMock.id))
    let invalidIgnore = try session.verifyNoMoreInteractions(
        in: .session, consumptionScope: first, ignoring: [foreignSelector])
    #expect(invalidIgnore.outcome == .foreignMock(foreignMock.id))

    _ = try session.resetHistory()
    let current = session.consumptionScope(named: first.name)
    #expect(throws: SessionConsumptionError.staleEpoch) {
        try session.verifyNoMoreInteractions(in: .session, consumptionScope: first)
    }
    #expect(throws: SessionConsumptionError.staleEpoch) {
        try session.verifyNoMoreInteractions(in: .session, consumptionScope: current, since: original)
    }
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: current).passed)
}
