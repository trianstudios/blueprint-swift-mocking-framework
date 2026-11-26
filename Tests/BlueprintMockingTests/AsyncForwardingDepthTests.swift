import Testing
@testable import BlueprintMocking

private enum DepthTestFailure: Error, Equatable {
    case missingTarget
    case depthExceeded
}

private actor DepthTestRedirect {
    private weak var endpoint: AsyncThrowingEndpoint<Int, Int, DepthTestFailure>?

    func bind(_ endpoint: AsyncThrowingEndpoint<Int, Int, DepthTestFailure>) {
        self.endpoint = endpoint
    }

    func call(_ input: Int) async throws(DepthTestFailure) -> Int {
        guard let endpoint else { throw .missingTarget }
        return try await endpoint.invoke(input)
    }
}

@Test func RUN018_depthLimitPublishesOneTypedFailureAndPairedEvents() async throws {
    let session = MockSession()
    let issues = CriticalState<[MockIssue]>([])
    let redirected = DepthTestRedirect()
    let attempted = CriticalState<[Int]>([])
    let setup = AsyncThrowingStubbing<Int, Int, DepthTestFailure>()
    setup.matching(.equal(0)).willReturn(0)
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("spy.depth"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue) } },
        scope: session.makeMock(),
        forwarding: AsyncThrowingForwarding(maximumDepth: 2) { input async throws(DepthTestFailure) in
            attempted.withLock { $0.append(input) }
            return try await redirected.call(input - 1) + 1
        }, failureMapping: { _ in .depthExceeded }
    )
    await redirected.bind(endpoint)

    do throws(DepthTestFailure) {
        _ = try await endpoint.invoke(3)
        Issue.record("Expected forwarding depth exhaustion")
    } catch {
        #expect(error == .depthExceeded)
    }

    let firstRun = session.snapshot()
    #expect(firstRun.activeInvocationCount == 0)
    #expect(firstRun.events.map(\.phase) == [.admitted, .admitted, .admitted, .threw, .threw, .threw])
    #expect(firstRun.events.map(\.origin) == [nil, nil, nil, nil, .forwarded, .forwarded])
    #expect(firstRun.events.prefix(3).map(\.invocationID) == Array(firstRun.events.suffix(3).map(\.invocationID).reversed()))
    #expect(attempted.withLock { $0 } == [3, 2])
    let issue = try #require(issues.withLock { $0.first })
    #expect(issues.withLock { $0.count } == 1)
    #expect(issue.message.contains("Forwarding depth limit 2 exceeded"))
    #expect(issue.watermark == 3)

    // The third invocation is stubbed, so being at the bound never affects it.
    #expect(try await endpoint.invoke(2) == 2)
    #expect(attempted.withLock { $0 } == [3, 2, 2, 1])
    #expect(issues.withLock { $0.count } == 1)
}

@Test func RUN018_unboundedForwardingParticipatesInLiveAncestry() async throws {
    let issues = CriticalState<[MockIssue]>([])
    let redirected = DepthTestRedirect()
    let inner = AsyncThrowingEndpoint(
        id: EndpointID("spy.depth.inner"), configuration: AsyncThrowingStubbing<Int, Int, DepthTestFailure>().finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue) } },
        forwarding: AsyncThrowingForwarding { input async throws(DepthTestFailure) in
            // A base case keeps a regression bounded and makes the assertion fail deterministically.
            guard input > 0 else { return 0 }
            return try await redirected.call(input - 1) + 1
        }, failureMapping: { _ in .depthExceeded }
    )
    await redirected.bind(inner)
    let outer = AsyncThrowingEndpoint(
        id: EndpointID("spy.depth.outer"), configuration: AsyncThrowingStubbing<Int, Int, DepthTestFailure>().finish(),
        failureReporter: FailureReporter { _ in Issue.record("The outer hop already called the provider") },
        forwarding: AsyncThrowingForwarding(maximumDepth: 2) { input async throws(DepthTestFailure) in
            try await inner.invoke(input)
        }, failureMapping: { _ in .depthExceeded }
    )

    await #expect(throws: DepthTestFailure.depthExceeded) { try await outer.invoke(3) }
    #expect(inner.invocations.map(\.origin) == [.forwarded, nil])
    #expect(outer.invocations.map(\.origin) == [.forwarded])
    #expect(issues.withLock { $0.map(\.endpoint.rawValue) } == ["spy.depth.inner"])
}

@Test(.timeLimit(.minutes(1))) func RUN018_depthLeaseDoesNotOutliveForwardedProvider() async throws {
    let (allowed, allow) = AsyncStream<Void>.makeStream()
    let child = CriticalState<Task<Int?, Never>?>(nil)
    let redirected = DepthTestRedirect()
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("spy.depth.escaped"), configuration: AsyncThrowingStubbing<Int, Int, DepthTestFailure>().finish(),
        failureReporter: FailureReporter { _ in Issue.record("Escaped task has no active ancestor") },
        forwarding: AsyncThrowingForwarding(maximumDepth: 1) { input async throws(DepthTestFailure) in
            if input == 1 {
                let nested = Task {
                    var work = allowed.makeAsyncIterator()
                    _ = await work.next()
                    return try? await redirected.call(7)
                }
                child.withLock { $0 = nested }
            }
            return input
        }, failureMapping: { _ in .depthExceeded }
    )
    await redirected.bind(endpoint)

    #expect(try await endpoint.invoke(1) == 1)
    let nested = try #require(child.withLock { $0 })
    allow.yield()
    #expect(await nested.value == 7)
    #expect(endpoint.invocations.map(\.origin) == [.forwarded, .forwarded])
}
