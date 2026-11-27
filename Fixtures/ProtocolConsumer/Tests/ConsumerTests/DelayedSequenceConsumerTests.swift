import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test(.timeLimit(.minutes(1)))
func RUN024_generatedDelayedSequenceKeepsTypedCancellationBeforeRegistration() async throws {
    let session = MockSession(clock: .manual)
    let captor = ArgumentCaptor<String>(session: session)
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.fetchUser(id: .any).capturing(into: captor, projecting: { id in
            if id == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return id
        }).willSequence(
            .returning("delayed", after: .seconds(2), onCancellation: .offline),
            .returning("next")
        )
    }
    let repository: any UserRepository = mock
    let first = Task { try await repository.fetchUser(id: "cancelled") }
    defer { first.cancel() }
    await #expect(throws: RepositoryError.offline) { try await first.value }
    #expect(try await repository.fetchUser(id: "second") == "next")

    let snapshot = session.snapshot()
    #expect(snapshot.events.map(\.phase) == [.admitted, .threw, .admitted, .returned])
    #expect(snapshot.cancellationRequests.count == 1)
    let request = try #require(snapshot.cancellationRequests.first)
    let firstTerminal = try #require(snapshot.events.first { $0.phase == .threw })
    #expect(request.admission.invocationID == firstTerminal.invocationID)
    #expect(request.ordinal < firstTerminal.ordinal)
}
