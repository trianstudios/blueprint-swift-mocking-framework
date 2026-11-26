import Testing
@testable import BlueprintMocking

private enum StructuralFailure: Error, Equatable {
    case unavailable(String)
}

private typealias LinkedEndpoint = AsyncThrowingEndpoint<Int, String, StructuralFailure>
private typealias Link = AsyncThrowingForwardingLink<Int, String, StructuralFailure>
private typealias Setup = AsyncThrowingStubbing<Int, String, StructuralFailure>

private func linked(
    _ name: String, session: MockSession, link: Link, setup: Setup = Setup(),
    issues: CriticalState<[MockIssue]>
) -> LinkedEndpoint {
    LinkedEndpoint(
        id: EndpointID(name), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue) } },
        scope: session.makeMock(), forwarding: AsyncThrowingForwarding(link: link),
        failureMapping: { .unavailable($0.message) }
    )
}

@Test func RUN018_asyncStructuralSelfTargetRejectsTheRevisitedFallback() async {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let link = Link()
    let endpoint = linked("self", session: session, link: link, issues: issues)
    #expect(link.bind(to: endpoint.forwardingTarget))
    #expect(!link.bind(to: endpoint.forwardingTarget))

    do throws(StructuralFailure) {
        _ = try await endpoint.invoke(1)
        Issue.record("Expected self forwarding to fail")
    } catch {
        #expect(error == .unavailable("Forwarding cycle detected for self: self -> self"))
    }

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .admitted, .threw, .threw])
    #expect(events.map(\.origin) == [nil, nil, nil, .forwarded])
    #expect(events.map(\.invocationID.rawValue) == [1, 2, 2, 1])
    #expect(issues.withLock { $0.map(\.watermark) } == [2])
}

@Test func RUN018_asyncStructuralIndirectCycleSettlesAllAdmittedHops() async {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let firstRoute = Link()
    let secondRoute = Link()
    let first = linked("first", session: session, link: firstRoute, issues: issues)
    let second = linked("second", session: session, link: secondRoute, issues: issues)
    defer { withExtendedLifetime(second) {} }
    #expect(firstRoute.bind(to: second.forwardingTarget))
    #expect(secondRoute.bind(to: first.forwardingTarget))

    do throws(StructuralFailure) {
        _ = try await first.invoke(2)
        Issue.record("Expected the repeated path to fail")
    } catch {
        #expect(error == .unavailable("Forwarding cycle detected for first: first -> second -> first"))
    }

    let events = session.snapshot().events
    #expect(events.map(\.endpoint.rawValue) == ["first", "second", "first", "first", "second", "first"])
    #expect(events.map(\.phase) == [.admitted, .admitted, .admitted, .threw, .threw, .threw])
    #expect(events.map(\.origin) == [nil, nil, nil, nil, .forwarded, .forwarded])
    #expect(events.map(\.invocationID.rawValue) == [1, 2, 3, 3, 2, 1])
    #expect(session.snapshot().activeInvocationCount == 0)
    #expect(issues.withLock { $0.map(\.endpoint.rawValue) } == ["first"])
}

@Test func RUN018_asyncStructuralLinkUsesInstanceIdentityAcrossSameNamedEndpoints() async throws {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let firstRoute = Link()
    let secondRoute = Link()
    let first = linked("same", session: session, link: firstRoute, issues: issues)
    let second = linked("same", session: session, link: secondRoute, issues: issues)
    let setup = Setup()
    setup.matching(.equal(7)).willReturn("target")
    let target = linked("target", session: session, link: Link(), setup: setup, issues: issues)
    defer { withExtendedLifetime((second, target)) {} }
    #expect(firstRoute.bind(to: second.forwardingTarget))
    #expect(secondRoute.bind(to: target.forwardingTarget))

    #expect(try await first.invoke(7) == "target")
    let snapshot = session.snapshot()
    #expect(snapshot.events.map(\.phase) == [.admitted, .admitted, .admitted, .returned, .returned, .returned])
    #expect(snapshot.events.map(\.origin) == [nil, nil, nil, nil, .forwarded, .forwarded])
    #expect(issues.withLock { $0.isEmpty })
}

@Test func RUN018_asyncStructuralLinkYieldsToMatchingAndExhaustedRules() async throws {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let route = Link()
    let setup = Setup()
    setup.matching(.equal(0)).willReturn("stub")
    setup.matching(.equal(1)).willSequence(.returning("sequence"))
    let endpoint = linked("self", session: session, link: route, setup: setup, issues: issues)
    #expect(route.bind(to: endpoint.forwardingTarget))

    #expect(try await endpoint.invoke(0) == "stub")
    #expect(try await endpoint.invoke(1) == "sequence")
    do throws(StructuralFailure) {
        _ = try await endpoint.invoke(1)
        Issue.record("Expected the finite sequence to be exhausted")
    } catch {
        #expect(error == .unavailable("Stub answer sequence exhausted for self"))
    }

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .threw])
    #expect(events.allSatisfy { $0.origin == nil })
    #expect(issues.withLock { $0.map(\.kind) } == [.sequenceExhausted])
}

@Test func RUN018_asyncStructuralLinkDistinguishesUnboundAndReleasedTargets() async {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let route = Link()
    let source = linked("source", session: session, link: route, issues: issues)

    do throws(StructuralFailure) {
        _ = try await source.invoke(0)
        Issue.record("Expected the unbound link to fail")
    } catch {
        #expect(error == .unavailable("Forwarding target is unbound for source"))
    }

    weak var weakTarget: LinkedEndpoint?
    do {
        let target = linked("target", session: session, link: Link(), issues: issues)
        weakTarget = target
        #expect(route.bind(to: target.forwardingTarget))
    }
    #expect(weakTarget == nil)
    #expect(!route.bind(to: source.forwardingTarget))

    do throws(StructuralFailure) {
        _ = try await source.invoke(0)
        Issue.record("Expected the released link to fail")
    } catch {
        #expect(error == .unavailable("Forwarding target was released for source"))
    }

    #expect(session.snapshot().events.map(\.phase) == [.admitted, .threw, .admitted, .threw])
    #expect(session.snapshot().events.map(\.origin) == [nil, nil, nil, nil])
    #expect(issues.withLock { $0.count } == 2)
}

@Test func RUN018_asyncStructuralLinkRespectsAnActiveDepthBudget() async {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let route = Link()
    let child = linked("child", session: session, link: route, issues: issues)
    let setup = Setup()
    setup.matching(.any).willReturn("real target")
    let target = linked("target", session: session, link: Link(), setup: setup, issues: issues)
    defer { withExtendedLifetime(target) {} }
    #expect(route.bind(to: target.forwardingTarget))
    let parent = LinkedEndpoint(
        id: EndpointID("parent"), configuration: Setup().finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue) } },
        scope: session.makeMock(),
        forwarding: AsyncThrowingForwarding(maximumDepth: 1) { input async throws(StructuralFailure) in
            try await child.invoke(input)
        }, failureMapping: { .unavailable($0.message) }
    )

    do throws(StructuralFailure) {
        _ = try await parent.invoke(0)
        Issue.record("Expected forwarding depth to be exhausted before the link target")
    } catch {
        #expect(error == .unavailable("Forwarding depth limit 1 exceeded for child"))
    }

    let events = session.snapshot().events
    #expect(events.map(\.endpoint.rawValue) == ["parent", "child", "child", "parent"])
    #expect(events.map(\.origin) == [nil, nil, nil, .forwarded])
    #expect(target.invocations.isEmpty)
    #expect(issues.withLock { $0.count } == 1)
}
