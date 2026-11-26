import Testing
import BlueprintMocking

private func makeOrderedEndpoint(
    _ name: String,
    scope: MockScope,
    reporter: FailureReporter,
    answer: @escaping @Sendable (String) -> String = { $0 }
) -> SyncEndpoint<String, String> {
    let setup = SyncStubbing<String, String>()
    setup.matching(.any).willAnswer(answer)
    return SyncEndpoint(
        id: EndpointID(name),
        configuration: setup.finish(),
        failureReporter: reporter,
        scope: scope
    )
}

private func selector(_ scope: MockScope, _ name: String) -> SessionCallSelector {
    SessionCallSelector(mockID: scope.id, endpoint: EndpointID(name))
}

@Test func RUN029_relativeAndStrictOrderDifferAcrossReentrantInvocations() {
    let session = MockSession()
    let outerScope = session.makeMock()
    let innerScope = session.makeMock()
    let finalScope = session.makeMock()
    let issues = Issues()
    let inner = makeOrderedEndpoint("inner", scope: innerScope, reporter: issues.reporter)
    let outer = makeOrderedEndpoint("outer", scope: outerScope, reporter: issues.reporter) { value in
        inner.invoke(value)
    }
    let final = makeOrderedEndpoint("final", scope: finalScope, reporter: issues.reporter)

    #expect(outer.invoke("first") == "first")
    #expect(final.invoke("last") == "last")

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let completions = snapshot.events.filter { $0.phase == .returned }
    #expect(admissions.map(\.mockID) == [outerScope.id, innerScope.id, finalScope.id])
    #expect(completions.map(\.mockID) == [innerScope.id, outerScope.id, finalScope.id])
    let expected = [selector(outerScope, "outer"), selector(finalScope, "final")]
    #expect(snapshot.matchOrder(expected, mode: .relative) == .matched(
        admissions.filter { $0.mockID != innerScope.id }
    ))
    #expect(snapshot.matchOrder(expected, mode: .strict) == .notMatched)
    #expect(snapshot.matchOrder(expected, mode: .strict, phase: .returned) == .matched(
        completions.filter { $0.mockID != innerScope.id }
    ))
    #expect(snapshot.matchOrder(expected, mode: .relative, phase: .threw) == .notMatched)
    #expect(issues.values.isEmpty)
}

@Test func RUN029_repeatedSelectorsChooseEarliestMatchingEvents() throws {
    let session = MockSession()
    let firstScope = session.makeMock()
    let secondScope = session.makeMock()
    let issues = Issues()
    // Both doubles deliberately use the same endpoint name.
    let first = makeOrderedEndpoint("shared", scope: firstScope, reporter: issues.reporter)
    let second = makeOrderedEndpoint("shared", scope: secondScope, reporter: issues.reporter)
    for endpoint in [first, first, first, second, first, first, second] {
        _ = endpoint.invoke("value")
    }

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    try #require(admissions.count == 7)
    let alpha = selector(firstScope, "shared")
    let beta = selector(secondScope, "shared")
    let expected = [alpha, alpha, beta]
    #expect(snapshot.matchOrder(expected, mode: .relative) == .matched(
        [admissions[0], admissions[1], admissions[3]]
    ))
    #expect(snapshot.matchOrder(expected, mode: .strict) == .matched(
        Array(admissions[1...3])
    ))
    #expect(snapshot.matchOrder([selector(firstScope, "not recorded")], mode: .relative) == .notMatched)
    #expect(snapshot.matchOrder([], mode: .strict) == .matched([]))
    #expect(issues.values.isEmpty)
}

@Test func RUN029_foreignSelectorsAreRejectedEvenWhenOrdinalsAndEndpointNamesAgree() {
    let local = MockSession()
    let foreign = MockSession()
    let localScope = local.makeMock()
    let foreignScope = foreign.makeMock()
    let issues = Issues()
    let localEndpoint = makeOrderedEndpoint("shared", scope: localScope, reporter: issues.reporter)
    let foreignEndpoint = makeOrderedEndpoint("shared", scope: foreignScope, reporter: issues.reporter)
    _ = localEndpoint.invoke("same")
    _ = foreignEndpoint.invoke("same")
    #expect(localScope.id.rawValue == foreignScope.id.rawValue)
    #expect(local.snapshot().events.map(\.ordinal) == foreign.snapshot().events.map(\.ordinal))

    let localSelector = selector(localScope, "shared")
    let foreignSelector = selector(foreignScope, "shared")
    let snapshot = local.snapshot()
    #expect(snapshot.matchOrder([localSelector, foreignSelector], mode: .relative) == .foreignMock(foreignScope.id))
    #expect(snapshot.matchOrder([foreignSelector], mode: .strict) == .foreignMock(foreignScope.id))
    #expect(issues.values.isEmpty)
}
