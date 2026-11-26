import Dispatch
import Testing
import BlueprintMocking

private func makeConsumptionEndpoint(_ session: MockSession)
    -> (ProjectedSyncEndpoint<String, String, String, Int>, SessionCallSelector) {
    let scope = session.makeMock()
    let endpoint = EndpointID("projected consumption")
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let projected = ProjectedSyncEndpoint(
        id: endpoint, configuration: stubs.finish(),
        projection: InvocationProjection(argument: { $0 }, result: { $0.count }),
        failureReporter: FailureReporter { issue in Issue.record("\(issue.message)") },
        scope: scope
    )
    return (projected, SessionCallSelector(mockID: scope.id, endpoint: endpoint))
}

@Test func RUN027_projectedConsumptionReturnsOnlySuccessfulClaims() throws {
    let session = MockSession()
    let (endpoint, selector) = makeConsumptionEndpoint(session)
    let scope = session.consumptionScope(named: "projected capture")
    _ = endpoint.invoke("first")
    _ = endpoint.invoke("second")
    let admissions = session.snapshot().events.filter { $0.phase == .admitted }

    let first = try endpoint.consume(.earliest(1), matchingArgument: .any, in: scope)
    #expect(first.claim.invocationIDs == [admissions[0].invocationID])
    #expect(first.captures.map(\.sessionInvocationID) == first.claim.invocationIDs)
    #expect(first.captures.first?.argument == .value("first"))
    #expect(first.captures.first?.result == .value(5))

    #expect(throws: ProjectedConsumptionError.claim(.insufficientMatches(requested: 2, available: 1))) {
        try endpoint.consume(.earliest(2), matchingArgument: .any, in: scope)
    }
    let remaining = try endpoint.consume(.all, matchingArgument: .any, in: scope)
    #expect(remaining.claim.invocationIDs == [admissions[1].invocationID])
    #expect(remaining.captures.first?.argument == .value("second"))
    #expect(try session.verifyNoMoreInteractions(in: .mock(selector.mockID), consumptionScope: scope).passed)
    #expect(endpoint.projectedHistory().calls.count == 2)
}

@Test func RUN027_competingClaimCannotLeakProjectedCapturesOrClaimAnotherCall() throws {
    let session = MockSession()
    let (endpoint, selector) = makeConsumptionEndpoint(session)
    let scope = session.consumptionScope(named: "same scope")
    _ = endpoint.invoke("first")
    _ = endpoint.invoke("second")

    let matcher = Matcher<String> { value in
        if value == "first" {
            let competing = try? session.consume(.earliest(1), for: selector, in: scope)
            #expect(competing?.invocationIDs.count == 1)
        }
        return true
    }
    #expect(throws: ProjectedConsumptionError.claim(.conflict)) {
        try endpoint.consume(.all, matchingArgument: matcher, in: scope)
    }
    let remaining = try endpoint.consume(.all, matchingArgument: .any, in: scope)
    #expect(remaining.captures.map(\.argument) == [.value("second")])
}

@Test func RUN027_resetDuringProjectedMatchingInvalidatesThePreparedCapture() throws {
    let session = MockSession()
    let (endpoint, _) = makeConsumptionEndpoint(session)
    let stale = session.consumptionScope(named: "before reset")
    _ = endpoint.invoke("retired")

    let matcher = Matcher<String> { _ in
        #expect((try? session.resetHistory()) != nil)
        return true
    }
    #expect(throws: ProjectedConsumptionError.claim(.staleEpoch)) {
        try endpoint.consume(.all, matchingArgument: matcher, in: stale)
    }
    let current = session.consumptionScope(named: stale.name)
    _ = endpoint.invoke("current")
    let newCapture = try endpoint.consume(.all, matchingArgument: .any, in: current)
    #expect(newCapture.captures.map(\.argument) == [.value("current")])
}

@Test func RUN027_pruningDuringProjectedMatchingPreventsCommit() throws {
    let session = MockSession()
    let (endpoint, _) = makeConsumptionEndpoint(session)
    let scope = session.consumptionScope(named: "pruned")
    _ = endpoint.invoke("retained only by the typed endpoint")

    let matcher = Matcher<String> { _ in
        let checkpoint = session.checkpoint()
        do { try session.discardEvents(through: checkpoint) }
        catch { Issue.record("Unexpected prune error: \(error)") }
        return true
    }
    #expect(throws: ProjectedConsumptionError.claim(.historyUnavailable)) {
        try endpoint.consume(.all, matchingArgument: matcher, in: scope)
    }
    #expect(endpoint.projectedHistory().calls.count == 1)
}

@Test func RUN027_pendingArgumentCannotBeConsumedAsAnEmptyMatch() throws {
    let session = MockSession()
    let scope = session.consumptionScope(named: "pending projection")
    let mock = session.makeMock()
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let worker = DispatchGroup()
    defer { resume.signal() }

    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("pending"), configuration: stubs.finish(),
        projection: InvocationProjection(
            argument: { (input: String) in
                entered.signal()
                _ = resume.wait(timeout: .now() + .seconds(5))
                return input
            },
            result: { (output: String) in output }
        ),
        failureReporter: FailureReporter { issue in Issue.record("\(issue.message)") },
        scope: mock
    )
    DispatchQueue.global().async(group: worker) { _ = endpoint.invoke("forward") }
    try #require(entered.wait(timeout: .now() + .seconds(5)) == .success)
    let admission = try #require(session.snapshot().events.first)

    #expect(throws: ProjectedConsumptionError.pendingProjection(admission.invocationID)) {
        try endpoint.consume(.all, matchingArgument: .any, in: scope)
    }
    let before = try session.verifyNoMoreInteractions(in: .mock(mock.id), consumptionScope: scope)
    #expect(before.outcome == .interaction(admission))

    resume.signal()
    try #require(worker.wait(timeout: .now() + .seconds(5)) == .success)
    let completed = try endpoint.consume(.all, matchingArgument: .any, in: scope)
    #expect(completed.claim.invocationIDs == [admission.invocationID])
    #expect(completed.captures.map(\.result) == [.value("forward")])
}
