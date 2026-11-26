import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private actor OpaqueStructuralSpyDirectory: StructuralSpyDirectory {
    private weak var redirect: (any StructuralSpyDirectory & AnyObject)?
    private(set) var forwardedValues: [Int] = []

    func redirect(to target: any StructuralSpyDirectory & AnyObject) {
        redirect = target
    }

    func fetch(_ value: Int) async throws(StructuralSpyFailure) -> Int {
        forwardedValues.append(value)
        guard value > 0, let redirect else { throw .fixtureEscape }
        return try await redirect.fetch(value - 1) + 1
    }
}

private enum StructuralForwardingSignal: Equatable, Sendable {
    case entered(Int)
    case settled(Int)
}

private actor BlockingStructuralSpyDirectory: StructuralSpyDirectory {
    private let signals: AsyncStream<StructuralForwardingSignal>.Continuation
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(signals: AsyncStream<StructuralForwardingSignal>.Continuation) {
        self.signals = signals
    }

    func fetch(_ value: Int) async throws(StructuralSpyFailure) -> Int {
        if !isReleased {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                signals.yield(.entered(value))
            }
        }
        return value * 10
    }

    func release() {
        isReleased = true
        let pending = held
        held.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private func fetchSignalingSettlement(
    _ value: Int,
    from client: StructuralSpyClient,
    signals: AsyncStream<StructuralForwardingSignal>.Continuation
) async -> Result<Int, StructuralSpyFailure> {
    // A premature failure releases the test's observation loop too.
    defer { signals.yield(.settled(value)) }
    do throws(StructuralSpyFailure) {
        return .success(try await client.fetch(value))
    } catch {
        return .failure(error)
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN018_generatedStructuralSelfLinkRejectsCycleAndHonorsMatchingStub() async throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let link = AsyncThrowingForwardingLink<Int, Int, StructuralSpyFailure>()
    let mock = StructuralSpyDirectoryMock(
        failureReporter: FailureReporter { issues.set(issues.get() + [$0]) },
        session: session,
        forwardingLinks: .init { $0.fetch(Int.self, through: link) },
        failureMappings: .init { $0.fetch(Int.self) { _ in .cycle } }
    ) { stubs in
        stubs.fetch(.equal(6)).willReturn(60)
    }
    try #require(link.bind(to: mock.forwardingTargets.fetch(Int.self)))
    let client = StructuralSpyClient(directory: mock)

    await #expect(throws: StructuralSpyFailure.cycle) { try await client.fetch(9) }
    let rejection = session.snapshot()
    let rejected = rejection.events
    let reported = issues.get()
    #expect(reported.map(\.kind) == [.unexpectedCall])
    #expect(reported.first?.message.hasPrefix("Forwarding cycle detected for ") == true)
    #expect(reported.first?.endpoint == rejected.last?.endpoint)
    #expect(rejection.activeInvocationCount == 0)
    #expect(rejected.map(\.phase) == [.admitted, .admitted, .threw, .threw])
    #expect(rejected.map(\.origin) == [nil, nil, nil, .forwarded])
    #expect(Set(rejected.map(\.mockID)).count == 1)
    #expect(Set(rejected.map(\.invocationID)).count == 2)
    #expect(rejected.prefix(2).map(\.invocationID) == rejected.suffix(2).reversed().map(\.invocationID))

    #expect(try await client.fetch(6) == 60)
    #expect(issues.get().count == 1)
    let stubbed = session.snapshot().events.dropFirst(rejected.count)
    #expect(stubbed.map(\.phase) == [.admitted, .returned])
    #expect(stubbed.map(\.origin) == [nil, nil])
    #expect(mock.verify.fetch(.equal(6), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(.equal(6), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
}

@Test(.timeLimit(.minutes(1)))
func RUN018_generatedStructuralLinksReportIndirectCycleOnce() async throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let reporter = FailureReporter { issues.set(issues.get() + [$0]) }
    let fromFirst = AsyncThrowingForwardingLink<Int, Int, StructuralSpyFailure>()
    let fromSecond = AsyncThrowingForwardingLink<Int, Int, StructuralSpyFailure>()
    let mappings = StructuralSpyDirectoryMock.FailureMappings { $0.fetch(Int.self) { _ in .cycle } }
    let first = StructuralSpyDirectoryMock(
        failureReporter: reporter, session: session,
        forwardingLinks: .init { $0.fetch(Int.self, through: fromFirst) }, failureMappings: mappings
    ) { _ in }
    let second = StructuralSpyDirectoryMock(
        failureReporter: reporter, session: session,
        forwardingLinks: .init { $0.fetch(Int.self, through: fromSecond) }, failureMappings: mappings
    ) { _ in }
    try #require(fromFirst.bind(to: second.forwardingTargets.fetch(Int.self)))
    try #require(fromSecond.bind(to: first.forwardingTargets.fetch(Int.self)))
    let client = StructuralSpyClient(directory: first)

    await #expect(throws: StructuralSpyFailure.cycle) { try await client.fetch(9) }
    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    let reported = issues.get()
    #expect(reported.map(\.kind) == [.unexpectedCall])
    #expect(reported.first?.message.hasPrefix("Forwarding cycle detected for ") == true)
    #expect(reported.first?.endpoint == outcomes.first?.endpoint)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(snapshot.events.map(\.phase) == [.admitted, .admitted, .admitted, .threw, .threw, .threw])
    #expect(Set(admissions.map(\.mockID)).count == 2)
    #expect(Set(admissions.map(\.endpoint.rawValue)).count == 1)
    #expect(admissions.first?.mockID == admissions.last?.mockID)
    #expect(Set(admissions.map(\.invocationID)).count == 3)
    #expect(admissions.map(\.invocationID) == outcomes.reversed().map(\.invocationID))
    #expect(outcomes.map(\.origin) == [nil, .forwarded, .forwarded])
    #expect(second.verify.fetch(.equal(9), phase: .threw, origin: .forwarded).wasCalled(.once).passed)
}

@Test(.timeLimit(.minutes(1)))
func RUN018_generatedStructuralRouteAllowsIndependentConcurrentRequests() async throws {
    let session = MockSession()
    let signals = AsyncStream<StructuralForwardingSignal>.makeStream()
    let real = BlockingStructuralSpyDirectory(signals: signals.continuation)
    let link = AsyncThrowingForwardingLink<Int, Int, StructuralSpyFailure>()
    let mappings = StructuralSpyDirectoryMock.FailureMappings { $0.fetch(Int.self) { _ in .cycle } }
    let root = StructuralSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session,
        forwardingLinks: .init { $0.fetch(Int.self, through: link) }, failureMappings: mappings
    ) { _ in }
    let leaf = StructuralSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: real, failureMappings: mappings
    ) { _ in }
    try #require(link.bind(to: leaf.forwardingTargets.fetch(Int.self)))
    let client = StructuralSpyClient(directory: root)
    var iterator = signals.stream.makeAsyncIterator()
    let first = Task { await fetchSignalingSettlement(1, from: client, signals: signals.continuation) }
    #expect(await iterator.next() == .entered(1))
    let second = Task { await fetchSignalingSettlement(2, from: client, signals: signals.continuation) }
    #expect(await iterator.next() == .entered(2))
    #expect(session.snapshot().activeInvocationCount == 4)
    await real.release()
    #expect(await first.value == .success(10))
    #expect(await second.value == .success(20))
    signals.continuation.finish()

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase == .returned }
    #expect(snapshot.activeInvocationCount == 0)
    #expect(admissions.count == 4)
    #expect(outcomes.count == 4)
    #expect(Set(admissions.map(\.invocationID)) == Set(outcomes.map(\.invocationID)))
    #expect(Set(admissions.map(\.mockID)).count == 2)
    #expect(outcomes.allSatisfy { $0.origin == .forwarded })
    #expect(leaf.verify.fetch(.any, phase: .returned, origin: .forwarded).wasCalled(.exactly(2)).passed)
}

@Test func RUN018_generatedStructuralRouteAllowsOpaqueReentryAroundItsEdge() async throws {
    let session = MockSession()
    let real = OpaqueStructuralSpyDirectory()
    let link = AsyncThrowingForwardingLink<Int, Int, StructuralSpyFailure>()
    let mappings = StructuralSpyDirectoryMock.FailureMappings { $0.fetch(Int.self) { _ in .cycle } }
    let root = StructuralSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session,
        forwardingLinks: .init { $0.fetch(Int.self, through: link) }, failureMappings: mappings
    ) { $0.fetch(.equal(0)).willReturn(10) }
    let leaf = StructuralSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: real, failureMappings: mappings
    ) { _ in }
    try #require(link.bind(to: leaf.forwardingTargets.fetch(Int.self)))
    await real.redirect(to: root)
    let client = StructuralSpyClient(directory: root)

    #expect(try await client.fetch(2) == 12)
    #expect(await real.forwardedValues == [2, 1])
    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase == .returned }
    #expect(snapshot.activeInvocationCount == 0)
    #expect(admissions.count == 5)
    #expect(outcomes.map(\.origin) == [nil, .forwarded, .forwarded, .forwarded, .forwarded])
    #expect(admissions.map(\.invocationID) == outcomes.reversed().map(\.invocationID))
    #expect(root.verify.fetch(.equal(0), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
    #expect(leaf.verify.fetch(.any, phase: .returned, origin: .forwarded).wasCalled(.exactly(2)).passed)
}
