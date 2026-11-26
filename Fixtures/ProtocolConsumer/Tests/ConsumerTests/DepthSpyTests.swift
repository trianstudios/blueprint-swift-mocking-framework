import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private actor ReenteringDepthSpyDirectory: DepthSpyDirectory {
    private let nextValue: @Sendable (Int) -> Int
    private weak var redirect: (any DepthSpyDirectory & AnyObject)?
    private(set) var forwardedValues: [Int] = []

    init(nextValue: @escaping @Sendable (Int) -> Int) {
        self.nextValue = nextValue
    }

    func redirect(to target: any DepthSpyDirectory & AnyObject) {
        redirect = target
    }

    func fetch(_ value: Int) async throws(DepthSpyFailure) -> Int {
        forwardedValues.append(value)
        // Bound the fixture even if the generated depth guard regresses.
        guard forwardedValues.count < 4, let redirect else { throw .fixtureEscape }
        return try await redirect.fetch(nextValue(value)) + 1
    }
}

@Test func RUN018_generatedAsyncSpyBoundsRealHopsInOpaqueReentry() async {
    let real = ReenteringDepthSpyDirectory { $0 }
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = DepthSpyDirectoryMock(
        failureReporter: FailureReporter { issue in issues.set(issues.get() + [issue]) },
        session: session, forwardingTo: real, maximumAsyncThrowingForwardingDepth: 2,
        failureMappings: .init { mappings in
            mappings.fetch(Int.self) { issue in
                #expect(issue.kind == .unexpectedCall)
                #expect(issue.message.hasPrefix("Forwarding depth limit 2 exceeded for "))
                return .forwardingLimit
            }
        }
    ) { _ in }
    await real.redirect(to: mock)
    let client = DepthSpyClient(directory: mock)

    await #expect(throws: DepthSpyFailure.forwardingLimit) { try await client.fetch(9) }
    #expect(await real.forwardedValues == [9, 9])
    let reported = issues.get()
    #expect(reported.map(\.kind) == [.unexpectedCall])
    #expect(reported.first?.message.hasPrefix("Forwarding depth limit 2 exceeded for ") == true)
    #expect(mock.verify.fetch(.equal(9), phase: .threw).wasCalled(.exactly(3)).passed)
    #expect(mock.verify.fetch(.equal(9), phase: .threw, origin: .forwarded).wasCalled(.exactly(2)).passed)

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    #expect(snapshot.events.map(\.phase) == [.admitted, .admitted, .admitted, .threw, .threw, .threw])
    #expect(snapshot.activeInvocationCount == 0)
    #expect(admissions.allSatisfy { $0.origin == nil })
    #expect(Set(admissions.map(\.invocationID)).count == 3)
    #expect(admissions.map(\.invocationID) == Array(outcomes.reversed()).map(\.invocationID))
    #expect(outcomes.map(\.origin) == [nil, .forwarded, .forwarded])
    #expect(reported.first?.endpoint == outcomes.first?.endpoint)
}

@Test func RUN018_generatedAsyncSpyLetsMatchingBaseStubWinAtForwardingLimit() async throws {
    let real = ReenteringDepthSpyDirectory { $0 - 1 }
    let session = MockSession()
    let mock = DepthSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: real, maximumAsyncThrowingForwardingDepth: 2
    ) { stubs in
        stubs.fetch(.equal(0)).willReturn(10)
    }
    await real.redirect(to: mock)
    let client = DepthSpyClient(directory: mock)

    #expect(try await client.fetch(2) == 12)
    #expect(await real.forwardedValues == [2, 1])
    #expect(mock.verify.fetch(.equal(0), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(.equal(0), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
    #expect(mock.verify.fetch(.equal(1), phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.fetch(.equal(2), phase: .returned, origin: .forwarded).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    #expect(snapshot.events.map(\.phase) == [.admitted, .admitted, .admitted, .returned, .returned, .returned])
    #expect(snapshot.activeInvocationCount == 0)
    #expect(Set(admissions.map(\.invocationID)).count == 3)
    #expect(admissions.map(\.invocationID) == Array(outcomes.reversed()).map(\.invocationID))
    #expect(outcomes.map(\.origin) == [nil, .forwarded, .forwarded])
}
