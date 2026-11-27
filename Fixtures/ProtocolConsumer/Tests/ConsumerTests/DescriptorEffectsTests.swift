import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN007_typedAsyncDescriptorSetupAndVerificationDoNotInvokeWitness() async throws {
    let id = "42"
    let session = MockSession()
    let answerCalls = StoredProperty(0)
    let issues = StoredProperty<[MockIssue]>([])
    let reporter = FailureReporter { issue in issues.set(issues.get() + [issue]) }
    let beforeSetup = session.snapshot()

    let mock = UserRepositoryMock(failureReporter: reporter, session: session) { stubs in
        let descriptor: AsyncThrowingStub<String, String, RepositoryError> = stubs.fetchUser(id: .equal(id))
        descriptor.willAnswer { userID async throws(RepositoryError) in
            answerCalls.set(answerCalls.get() + 1)
            return "User \(userID)"
        }
    }

    #expect(session.snapshot() == beforeSetup)
    #expect(answerCalls.get() == 0)
    #expect(issues.get().isEmpty)

    let verification = verifyNoFetchCalls(mock, id: id)
    #expect(verification.passed)
    #expect(verification.observed == 0)
    #expect(verification.invocationIDs.isEmpty)
    #expect(session.snapshot() == beforeSetup)
    #expect(answerCalls.get() == 0)
    #expect(issues.get().isEmpty)

    let service = UserService(repository: mock)
    #expect(try await service.load(id: id) == "User 42")

    let afterCall = session.snapshot()
    try #require(afterCall.events.count == 2)
    let admission = afterCall.events[0]
    let completion = afterCall.events[1]
    #expect(admission.phase == .admitted)
    #expect(completion.phase == .returned)
    #expect(admission.endpoint == EndpointID(
        "schema1|ConsumerDomain.UserRepository|fetchUser(id:String) async throws(RepositoryError)->String|Sendable"
    ))
    #expect(completion.endpoint == admission.endpoint)
    #expect(completion.invocationID == admission.invocationID)
    #expect(completion.mockID == admission.mockID)
    #expect(admission.epoch == beforeSetup.epoch)
    #expect(completion.epoch == admission.epoch)
    #expect(completion.configurationRevision == admission.configurationRevision)
    #expect(admission.ordinal == beforeSetup.watermark + 1)
    #expect(completion.ordinal == admission.ordinal + 1)
    #expect(afterCall.watermark == completion.ordinal)
    #expect(afterCall.activeInvocationCount == 0)
    #expect(answerCalls.get() == 1)
    #expect(issues.get().isEmpty)
}

private func verifyNoFetchCalls(_ mock: UserRepositoryMock, id: String) -> VerificationResult {
    let descriptor: BlueprintMocking.Verification<String> = mock.verify.fetchUser(id: .equal(id))
    return descriptor.wasCalled(.never)
}
