import Testing
@testable import BlueprintMocking

private func consumptionEndpoint(
    scope: MockScope, name: String = "load"
) -> (SyncEndpoint<Int, Int>, SessionCallSelector) {
    let id = EndpointID(name)
    let stubs = SyncStubbing<Int, Int>()
    stubs.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(id: id, configuration: stubs.finish(), failureReporter: FailureReporter { _ in },
                                scope: scope)
    return (endpoint, SessionCallSelector(mockID: scope.id, endpoint: id))
}

@Test func RUN027_earliestAndAllRespectNamedScopeAndAdmissionOrder() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    for value in 1...3 { _ = endpoint.invoke(value) }
    let ids = endpoint.invocations.map(\.sessionInvocationID)
    let first = session.consumptionScope(named: "first")
    let sameScope = session.consumptionScope(named: "first")
    let other = session.consumptionScope(named: "other")
    #expect(first == sameScope)

    let earliest = try session.consume(.earliest(2), for: selector, in: first)
    #expect(earliest.invocationIDs == Array(ids.prefix(2)))
    #expect(earliest.scope == first)
    #expect(earliest.watermark == session.snapshot().watermark)
    #expect(try session.consume(.all, for: selector, in: sameScope).invocationIDs == [ids[2]])
    #expect(try session.consume(.all, for: selector, in: other).invocationIDs == ids)
    #expect(try session.consume(.all, for: selector, in: first).invocationIDs.isEmpty)
}

@Test func RUN027_competingSelectionsConflictWithoutPartialClaims() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    _ = endpoint.invoke(1)
    _ = endpoint.invoke(2)
    let ids = endpoint.invocations.map(\.sessionInvocationID)
    let scope = session.consumptionScope(named: "check")

    let first = try session.prepareConsumption(.earliest(1), for: selector, in: scope)
    let competitor = try session.prepareConsumption(.all, for: selector, in: scope)
    #expect(try session.commitConsumption(first).invocationIDs == [ids[0]])
    #expect(throws: SessionConsumptionError.conflict) { try session.commitConsumption(competitor) }
    let remaining = try session.consume(.all, for: selector, in: scope)
    #expect(remaining.invocationIDs == [ids[1]])
}

@Test func RUN027_newEventsAndOtherScopesDoNotChangePreparedSelection() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let first = session.consumptionScope(named: "first")
    let second = session.consumptionScope(named: "second")
    _ = endpoint.invoke(1)
    let firstID = try #require(endpoint.invocations.first?.sessionInvocationID)
    let prepared = try session.prepareConsumption(.all, for: selector, in: first)
    let watermark = session.snapshot().watermark

    _ = endpoint.invoke(2)
    let secondID = try #require(endpoint.invocations.last?.sessionInvocationID)
    _ = try session.consume(.all, for: selector, in: second)
    let result = try session.commitConsumption(prepared)

    #expect(result.watermark == watermark)
    #expect(result.invocationIDs == [firstID])
    #expect(try session.consume(.all, for: selector, in: first).invocationIDs == [secondID])
}

@Test func RUN027_failedAndEmptySelectionsDoNotAdvanceTheClaimCursor() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let scope = session.consumptionScope(named: "claims")
    _ = endpoint.invoke(1)
    let id = try #require(endpoint.invocations.first?.sessionInvocationID)
    let prepared = try session.prepareConsumption(.earliest(1), for: selector, in: scope)

    #expect(throws: SessionConsumptionError.insufficientMatches(requested: 2, available: 1)) {
        try session.consume(.earliest(2), for: selector, in: scope)
    }
    #expect(throws: SessionConsumptionError.invalidSelection) {
        try session.consume(.earliest(-1), for: selector, in: scope)
    }
    #expect(try session.consume(.earliest(0), for: selector, in: scope).invocationIDs.isEmpty)
    #expect(try session.commitConsumption(prepared).invocationIDs == [id])
}

@Test func RUN027_pruningAfterPreparationFailsCommitWithoutClaiming() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let scope = session.consumptionScope(named: "claims")
    _ = endpoint.invoke(1)
    let cutoff = session.checkpoint()
    _ = endpoint.invoke(2)
    let prepared = try session.prepareConsumption(.all, for: selector, in: scope)

    try session.discardEvents(through: cutoff)
    #expect(throws: SessionConsumptionError.historyUnavailable) {
        try session.commitConsumption(prepared)
    }
    #expect(throws: SessionConsumptionError.historyUnavailable) {
        try session.consume(.earliest(1), for: selector, in: scope)
    }
    #expect(try session.consumptionSnapshot(in: scope).consumedInvocationIDs.isEmpty)
}

@Test func RUN027_scopesRejectForeignSessionAndStaleEpoch() throws {
    let session = MockSession()
    let other = MockSession()
    let scope = session.consumptionScope(named: "claims")
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let (_, foreignSelector) = consumptionEndpoint(scope: other.makeMock())
    #expect(throws: SessionConsumptionError.foreignSession) {
        try other.consume(.all, for: foreignSelector, in: scope)
    }
    #expect(throws: SessionConsumptionError.foreignMock(foreignSelector.mockID)) {
        try session.consume(.all, for: foreignSelector, in: scope)
    }

    _ = endpoint.invoke(1)
    let prepared = try session.prepareConsumption(.all, for: selector, in: scope)
    _ = try session.consume(.all, for: selector, in: scope)
    _ = try session.resetHistory(.detachActive)
    #expect(throws: SessionConsumptionError.staleEpoch) { try session.commitConsumption(prepared) }
    #expect(throws: SessionConsumptionError.staleEpoch) {
        try session.consume(.all, for: selector, in: scope)
    }
    let fresh = session.consumptionScope(named: scope.name)
    #expect(fresh.epoch != scope.epoch)
    #expect(try session.consumptionSnapshot(in: fresh).consumedInvocationIDs.isEmpty)
}

@Test func RUN027_finishedSessionKeepsEventsImmutableWhileClaimingThem() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let scope = session.consumptionScope(named: "afterFinish")
    _ = endpoint.invoke(1)
    let final = try session.finishIfQuiescent()

    #expect(try session.consume(.all, for: selector, in: scope).invocationIDs.count == 1)
    #expect(session.snapshot() == final)
}

@Test func RUN027_disjointClaimsStillCompareTheSameNamedScopeRevision() throws {
    let session = MockSession()
    let (first, firstSelector) = consumptionEndpoint(scope: session.makeMock(), name: "first")
    let (second, secondSelector) = consumptionEndpoint(scope: session.makeMock(), name: "second")
    _ = first.invoke(1)
    _ = second.invoke(2)
    let scope = session.consumptionScope(named: "shared")
    let firstClaim = try session.prepareConsumption(.all, for: firstSelector, in: scope)
    let secondClaim = try session.prepareConsumption(.all, for: secondSelector, in: scope)

    _ = try session.commitConsumption(firstClaim)
    #expect(throws: SessionConsumptionError.conflict) { try session.commitConsumption(secondClaim) }
    #expect(try session.consume(.all, for: secondSelector, in: scope).invocationIDs.count == 1)
}

@Test func RUN027_competingOrderedSelectionsCommitTogetherOrLeaveEveryIDUnclaimed() throws {
    let session = MockSession()
    let mock = session.makeMock()
    let (a, selectA) = consumptionEndpoint(scope: mock, name: "a")
    let (b, selectB) = consumptionEndpoint(scope: mock, name: "b")
    let (c, selectC) = consumptionEndpoint(scope: mock, name: "c")
    _ = a.invoke(1)
    _ = b.invoke(2)
    _ = c.invoke(3)
    let aID = try #require(a.invocations.first?.sessionInvocationID)
    let bID = try #require(b.invocations.first?.sessionInvocationID)
    let cID = try #require(c.invocations.first?.sessionInvocationID)
    let scope = session.consumptionScope(named: "ordered claims")
    let winner = try #require(try session.prepareOrderedConsumption([selectA, selectB], mode: .strict, in: scope))
    let loser = try #require(try session.prepareOrderedConsumption([selectB, selectC], mode: .strict, in: scope))

    #expect(try session.commitConsumption(winner).invocationIDs == [aID, bID])
    #expect(throws: SessionConsumptionError.conflict) { try session.commitConsumption(loser) }
    #expect(try session.consumptionSnapshot(in: scope).consumedInvocationIDs == [aID, bID])
    #expect(try session.consume(.all, for: selectC, in: scope).invocationIDs == [cID])
}

@Test func RUN027_orderedClaimsCannotProveAnEarliestMatchAfterPruning() throws {
    let session = MockSession()
    let (endpoint, selector) = consumptionEndpoint(scope: session.makeMock())
    let scope = session.consumptionScope(named: "ordered claims")
    _ = endpoint.invoke(1)
    let cutoff = session.checkpoint()
    _ = endpoint.invoke(2)
    let prepared = try #require(try session.prepareOrderedConsumption([selector], mode: .strict, in: scope))

    try session.discardEvents(through: cutoff)
    #expect(throws: SessionConsumptionError.historyUnavailable) { try session.commitConsumption(prepared) }
    #expect(throws: SessionConsumptionError.historyUnavailable) {
        try session.consumeInOrder([selector], mode: .strict, in: scope)
    }
    #expect(try session.consumptionSnapshot(in: scope).consumedInvocationIDs.isEmpty)
}
