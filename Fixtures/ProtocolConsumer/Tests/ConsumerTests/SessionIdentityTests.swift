import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private enum SessionIdentitySignal: Sendable, Equatable {
    case entered(String)
    case settled(String)
}

private actor SessionIdentityGate {
    private let signals: AsyncStream<SessionIdentitySignal>.Continuation
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var isClosed = false

    init(signals: AsyncStream<SessionIdentitySignal>.Continuation) {
        self.signals = signals
    }

    func wait(for id: String) async {
        guard !isClosed else { return }
        await withCheckedContinuation { continuation in
            held[id] = continuation
            signals.yield(.entered(id))
        }
    }

    func release(_ id: String) -> Bool {
        guard let continuation = held.removeValue(forKey: id) else { return false }
        continuation.resume()
        return true
    }

    func close() {
        isClosed = true
        let remaining = held.values
        held.removeAll()
        for continuation in remaining { continuation.resume() }
    }
}

@Test(.timeLimit(.minutes(1)))
func SYS007_concurrentGeneratedCallsKeepUniqueSessionInvocationIDs() async throws {
    let session = MockSession()
    let signals = AsyncStream<SessionIdentitySignal>.makeStream()
    let gate = SessionIdentityGate(signals: signals.continuation)
    defer {
        signals.continuation.finish()
        Task { await gate.close() }
    }

    func makeMock(_ label: String) -> UserRepositoryMock {
        UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
            stubs.fetchUser(id: .any).willAnswer { id async throws(RepositoryError) in
                await gate.wait(for: id)
                if id.hasSuffix("-offline") { throw .offline }
                return "\(label)/\(id)"
            }
        }
    }

    let first = makeMock("first")
    let second = makeMock("second")
    let firstClient = UserService(repository: first)
    let secondClient = UserService(repository: second)
    let requests: [(id: String, client: UserService, returned: String?)] = [
        ("alpha", firstClient, "first/alpha"),
        ("beta-offline", secondClient, nil),
        ("gamma-offline", firstClient, nil),
        ("delta", secondClient, "second/delta"),
    ]

    var invocations: [Task<String, any Error>] = []
    var arrivals = signals.stream.makeAsyncIterator()
    for request in requests {
        invocations.append(Task {
            defer { signals.continuation.yield(.settled(request.id)) }
            return try await request.client.load(id: request.id)
        })
        let signal = await arrivals.next()
        // A call that settles without reaching its gate also wakes the observer.
        try #require(signal == .entered(request.id))
    }

    let active = session.snapshot()
    let admissions = active.events
    #expect(active.activeInvocationCount == requests.count)
    try #require(admissions.count == requests.count)
    #expect(admissions.allSatisfy { $0.phase == .admitted })
    #expect(admissions.allSatisfy { $0.epoch == active.epoch })
    #expect(admissions.allSatisfy { $0.invocationID.sessionID == session.id })
    #expect(admissions.allSatisfy { $0.endpoint == admissions[0].endpoint })
    #expect(Set(admissions.map(\.invocationID)).count == requests.count)
    #expect(Set(admissions.map(\.mockID)).count == 2)
    #expect(admissions[0].mockID == admissions[2].mockID)
    #expect(admissions[1].mockID == admissions[3].mockID)

    // Complete out of admission order. Join each release before opening the next gate.
    for index in requests.indices.reversed() {
        let released = await gate.release(requests[index].id)
        try #require(released)
        let invocation = invocations[index]
        if let expected = requests[index].returned {
            let value = try await invocation.value
            #expect(value == expected)
        } else {
            await #expect(throws: RepositoryError.offline) { try await invocation.value }
        }
    }

    let settled = session.snapshot()
    #expect(settled.activeInvocationCount == 0)
    #expect(settled.epoch == active.epoch)
    #expect(Array(settled.events.prefix(requests.count)) == admissions)
    let terminal = settled.events.dropFirst(requests.count)
    try #require(terminal.count == requests.count)
    #expect(terminal.map(\.invocationID) == admissions.reversed().map(\.invocationID))
    #expect(terminal.map(\.phase) == [.returned, .threw, .threw, .returned])
    let ordinals = settled.events.map(\.ordinal)
    #expect(zip(ordinals, ordinals.dropFirst()).allSatisfy { $0.0 < $0.1 })

    for (admission, completion) in zip(admissions.reversed(), terminal) {
        #expect(completion.endpoint == admission.endpoint)
        #expect(completion.mockID == admission.mockID)
        #expect(completion.epoch == admission.epoch)
        #expect(completion.configurationRevision == admission.configurationRevision)
        #expect(completion.ordinal > admission.ordinal)
    }
    #expect(first.verify.fetchUser(id: .equal("alpha"), phase: .returned).wasCalled(.once).passed)
    #expect(first.verify.fetchUser(id: .equal("gamma-offline"), phase: .threw).wasCalled(.once).passed)
    #expect(second.verify.fetchUser(id: .equal("delta"), phase: .returned).wasCalled(.once).passed)
    #expect(second.verify.fetchUser(id: .equal("beta-offline"), phase: .threw).wasCalled(.once).passed)
}
