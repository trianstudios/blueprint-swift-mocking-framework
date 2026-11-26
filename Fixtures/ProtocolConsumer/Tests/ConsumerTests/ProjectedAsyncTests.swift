import Testing
import BlueprintMocking
import BlueprintMockingTesting

private final class SensitiveParcel: Sendable {
    let contents: String

    init(_ contents: String) { self.contents = contents }
}

private enum ParcelFailure: Error {
    case offline
    case exhausted
    case cancelled
}

private protocol ParcelService: Sendable {
    func fetch(_ parcel: SensitiveParcel) async throws(ParcelFailure) -> SensitiveParcel
}

private struct ParcelUseCase {
    let service: any ParcelService

    func run(_ request: SensitiveParcel) async throws(ParcelFailure) -> SensitiveParcel {
        try await service.fetch(request)
    }
}

private struct ProjectedParcelDouble: ParcelService {
    let endpoint: ProjectedAsyncThrowingEndpoint<SensitiveParcel, SensitiveParcel, ParcelFailure, Int, Int>

    func fetch(_ parcel: SensitiveParcel) async throws(ParcelFailure) -> SensitiveParcel {
        try await endpoint.invoke(parcel)
    }
}

@Test func RUN040_projectedAsyncSequenceRetainsOnlyProjectionAndPreservesTypedFailure() async throws {
    let session = MockSession()
    let stubs = AsyncThrowingStubbing<SensitiveParcel, SensitiveParcel, ParcelFailure>()
    stubs.matching(.any).willSequence(
        .answering { input async throws(ParcelFailure) in
            await Task.yield()
            return SensitiveParcel("result: " + input.contents)
        },
        .throwing(.offline)
    )
    let projection = InvocationProjection<SensitiveParcel, SensitiveParcel, Int, Int>(
        argument: { value in
            #expect(session.snapshot().activeInvocationCount == 1)
            return value.contents.count
        },
        result: { $0.contents.count }
    )
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("fetch"), configuration: stubs.finish(), projection: projection,
        failureReporter: .swiftTesting, scope: session.makeMock(),
        failureMapping: { issue in
            #expect(issue.kind == .sequenceExhausted)
            return .exhausted
        }
    )
    let useCase = ParcelUseCase(service: ProjectedParcelDouble(endpoint: endpoint))
    var request: SensitiveParcel? = SensitiveParcel("internal request")
    weak var weakRequest = request
    var returned: SensitiveParcel? = try await useCase.run(try #require(request))
    weak var weakReturned = returned
    #expect(returned?.contents == "result: internal request")
    request = nil
    returned = nil
    #expect(weakRequest == nil)
    #expect(weakReturned == nil)

    await #expect(throws: ParcelFailure.offline) {
        try await useCase.run(SensitiveParcel("offline"))
    }
    await withKnownIssue("Exhausted projected sequence") {
        await #expect(throws: ParcelFailure.exhausted) {
            try await useCase.run(SensitiveParcel("exhausted"))
        }
    }
    let history = endpoint.projectedHistory()
    #expect(history.calls.map(\.argument) == [.value("internal request".count), .value(7), .value(9)])
    #expect(history.calls.map(\.result) == [.value("result: internal request".count), .unavailable, .unavailable])
    #expect(history.calls.map(\.phase) == [.returned, .threw, .threw])
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned, .admitted, .threw, .admitted, .threw])
}

@Test func RUN040_projectedAsyncCancellationCompletesItsOriginalEpoch() async throws {
    let session = MockSession()
    let originalEpoch = session.snapshot().epoch
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    let original = AsyncThrowingStubbing<SensitiveParcel, SensitiveParcel, ParcelFailure>()
    original.matching(.any).willAnswer { input async throws(ParcelFailure) in
        entered.continuation.finish()
        for await _ in release.stream {}
        if Task.isCancelled { throw .cancelled }
        return input
    }
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("interleaved fetch"), configuration: original.finish(),
        projection: InvocationProjection(argument: { $0.contents.count }, result: { $0.contents.count }),
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let useCase = ParcelUseCase(service: ProjectedParcelDouble(endpoint: endpoint))
    let old = Task {
        defer { entered.continuation.finish() }
        return try await useCase.run(SensitiveParcel("held"))
    }
    for await _ in entered.stream {}
    let suspended = try #require(endpoint.projectedHistory().calls.first)
    #expect(suspended.argument == .value(4))
    #expect(suspended.result == .pending)
    #expect(suspended.phase == .admitted)

    let newEpoch = try session.resetHistory(.detachActive)
    let replacement = AsyncThrowingStubbing<SensitiveParcel, SensitiveParcel, ParcelFailure>()
    replacement.matching(.any).willAnswer { _ in SensitiveParcel("new result") }
    let revision = endpoint.replaceConfiguration(replacement.finish())
    #expect(try await useCase.run(SensitiveParcel("new request")).contents == "new result")
    old.cancel()
    await #expect(throws: ParcelFailure.cancelled) { try await old.value }

    let history = endpoint.projectedHistory()
    #expect(history.epoch == newEpoch)
    try #require(history.calls.count == 1)
    let current = history.calls[0]
    #expect(current.argument == .value("new request".count))
    #expect(current.result == .value("new result".count))
    #expect(current.configurationRevision == revision)
    #expect(current.sessionInvocationID != suspended.sessionInvocationID)
    let scope = session.consumptionScope(named: "replacement projections")
    let committed = try endpoint.consume(.all, matchingArgument: .equal("new request".count), in: scope)
    #expect(committed.claim.invocationIDs == [current.sessionInvocationID])
    #expect(committed.captures.first?.result == .value("new result".count))
    #expect(try session.verifyNoMoreInteractions(in: .session, consumptionScope: scope).passed)
    let archived = try #require(session.snapshot(epoch: originalEpoch))
    #expect(archived.events.map(\.phase) == [.admitted, .threw])
    #expect(archived.events.allSatisfy { $0.invocationID == suspended.sessionInvocationID })
}

@Test func RUN040_projectedAsyncReturnedNilIsAvailable() async throws {
    let setup = AsyncThrowingStubbing<String, SensitiveParcel?, ParcelFailure>()
    setup.matching(.any).willReturn(nil)
    let projection = InvocationProjection<String, SensitiveParcel?, Int, Bool>(
        argument: { $0.count }, result: { $0 != nil }
    )
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("optional response"), configuration: setup.finish(), projection: projection,
        failureReporter: .swiftTesting
    )

    #expect(try await endpoint.invoke("none") == nil)
    let projected = try #require(endpoint.projectedHistory().calls.first)
    #expect(projected.result == .value(false))
    #expect(projected.phase == .returned)
}

@Test func RUN040_projectedOrdinaryThrowingMissReportsAndLeavesResultUnavailable() async throws {
    let setup = AsyncThrowingStubbing<String, SensitiveParcel, any Error>()
    let projection = InvocationProjection<String, SensitiveParcel, Int, Int>(
        argument: { $0.count },
        result: { _ in
            Issue.record("An unanswered throwing endpoint must not project a return value")
            return -1
        }
    )
    let endpoint = ProjectedAsyncThrowingEndpoint(
        id: EndpointID("ordinary miss"), configuration: setup.finish(), projection: projection,
        failureReporter: .swiftTesting
    )

    await withKnownIssue("Projected ordinary throwing call has no stub") {
        do {
            _ = try await endpoint.invoke("not stubbed")
            Issue.record("Expected an unexpected invocation error")
        } catch let error as UnexpectedInvocationError {
            #expect(error.issue.kind == .unexpectedCall)
            #expect(error.issue.endpoint == EndpointID("ordinary miss"))
        } catch {
            Issue.record("Expected UnexpectedInvocationError, got \(error)")
        }
    }
    let history = endpoint.projectedHistory()
    let projected = try #require(history.calls.first)
    #expect(projected.argument == .value("not stubbed".count))
    #expect(projected.result == .unavailable)
    #expect(projected.phase == .threw)
    let missing = history.verify(.never, matchingResult: .any, phase: .threw)
    #expect(missing.status == .incompleteHistory)
    #expect(missing.unavailableInvocationIDs == [projected.sessionInvocationID])
    #expect(missing.captures.isEmpty)
}
