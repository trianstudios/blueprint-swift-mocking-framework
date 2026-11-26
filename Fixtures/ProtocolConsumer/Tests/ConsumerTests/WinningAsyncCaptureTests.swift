import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func RUN009_generatedAsyncWinningCaptureCommitsOnlyReservedSequenceSteps() async throws {
    let session = MockSession()
    let selected = ArgumentCaptor<String>(session: session)
    let shadowed = ArgumentCaptor<String>(session: session)
    let mock = UserRepositoryMock(
        failureReporter: .swiftTesting, session: session,
        failureMappings: .init { mappings in
            mappings.fetchUser(id: String.self) { issue in
                #expect(issue.kind == .sequenceExhausted)
                return .offline
            }
        }
    ) { stubs in
        stubs.fetchUser(id: .any).capturing(into: shadowed, projecting: { $0 })
            .willReturn("shadowed")
        stubs.fetchUser(id: .any).capturing(into: selected, projecting: { String($0.prefix(1)) })
            .willSequence(
                .throwing(.offline),
                .answering { value async throws(RepositoryError) in
                    #expect(selected.captures.map(\.value) == ["a", "b"])
                    return "answered \(value)"
                }
            )
    }
    let service = UserService(repository: mock)

    await #expect(throws: RepositoryError.offline) {
        try await service.load(id: "alpha")
    }
    #expect(try await service.load(id: "beta") == "answered beta")
    await withKnownIssue("Exhaustion reports a runtime issue before its typed error mapping") {
        await #expect(throws: RepositoryError.offline) {
            try await service.load(id: "exhausted")
        }
    }
    let admissions = session.snapshot().events.filter { $0.phase == .admitted }
    #expect(selected.captures.map(\.value) == ["a", "b"])
    #expect(selected.captures.map(\.invocation) == Array(admissions.prefix(2)))
    #expect(admissions.count == 3)
    #expect(shadowed.captures.isEmpty)
}

private enum AsyncCaptureFailure: Error {
    case exhausted
}

@Test func RUN009_concurrentOneShotSequencePublishesExactlyOneWinningCapture() async {
    let session = MockSession()
    let selected = ArgumentCaptor<Int>(session: session)
    let setup = AsyncThrowingStubbing<Int, Int, AsyncCaptureFailure>()
    setup.matching(.any).capturing(into: selected, projecting: { $0 })
        .willSequence(.answering { value async throws(AsyncCaptureFailure) in
            await Task.yield()
            return value
        })
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("single-capture"), configuration: setup.finish(),
        failureReporter: FailureReporter { _ in }, scope: session.makeMock(),
        failureMapping: { _ in .exhausted }
    )
    let values = await withTaskGroup(of: Int?.self) { group in
        for input in 0..<16 { group.addTask { try? await endpoint.invoke(input) } }
        var returned: [Int] = []
        for await result in group { if let result { returned.append(result) } }
        return returned
    }
    #expect(values.count == 1)
    #expect(selected.captures.map(\.value) == values)
    #expect(endpoint.invocations.filter { $0.phase == .returned }.map(\.sessionInvocationID)
        == selected.captures.map(\.invocation.invocationID))
}

@Test func RUN009_projectedAsyncCaptureCarriesAdmittedRevisionAndRespectsReset() async throws {
    let session = MockSession()
    let selected = ArgumentCaptor<Int>(session: session)
    let entered = AsyncStream<Void>.makeStream()
    let released = AsyncStream<Void>.makeStream()
    defer { released.continuation.finish() }
    let initial = AsyncThrowingStubbing<String, String, AsyncCaptureFailure>()
    initial.matching(.any).capturing(into: selected, projecting: { input in
        _ = session.snapshot()
        return input.count
    }).willAnswer { value async throws(AsyncCaptureFailure) in
        entered.continuation.finish()
        for await _ in released.stream {}
        return value
    }
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("projected-async"), configuration: initial.finish(),
        projection: InvocationProjection(argument: { $0.count }, result: { $0.count }),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let old = Task { try await endpoint.invoke("old") }
    for await _ in entered.stream {}
    let historic = selected.captures
    #expect(historic.map(\.value) == [3])
    let oldEpoch = session.snapshot().epoch
    let newEpoch = try session.resetHistory(.detachActive)
    #expect(selected.captures.isEmpty)

    let next = AsyncThrowingStubbing<String, String, AsyncCaptureFailure>()
    next.matching(.any).capturing(into: selected, projecting: { $0.count })
        .willReturn("new")
    let revision = endpoint.replaceConfiguration(next.finish())
    #expect(try await endpoint.invoke("fresh") == "new")
    released.continuation.finish()
    #expect(try await old.value == "old")

    #expect(selected.captures.map(\.value) == [5])
    #expect(selected.captures.first?.invocation.epoch == newEpoch)
    #expect(selected.captures.first?.invocation.configurationRevision == revision)
    #expect(historic.map(\.value) == [3])
    let archived = try #require(session.snapshot(epoch: oldEpoch))
    #expect(archived.events.map(\.phase) == [.admitted, .returned])
}
