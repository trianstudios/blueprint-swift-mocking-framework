import Foundation
import Dispatch
import Testing
import BlueprintMocking
import BlueprintMockingTesting

private struct FrozenResponse: Equatable, Sendable {
    let text: String
}

// A reference whose mutable test data is accessed through its lock.
private final class ProjectionPayload: @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var text: String

    init(_ label: String, text: String) {
        self.label = label
        self.text = text
    }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        text = value
    }
}

private final class ProjectionPauseGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.continuation.finish()
        release.wait()
    }

    func waitUntilEntered() async {
        for await _ in entered.stream {}
    }

    func resume() {
        release.signal()
    }
}

// A synchronous projection can block a dispatch worker without blocking Swift's cooperative executor.
private func invokeOnDispatchWorker<Output: Sendable>(
    _ body: @escaping @Sendable () -> Output
) -> Task<Output, Never> {
    Task {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: body())
            }
        }
    }
}

private func isPending<Value: Sendable>(_ value: ProjectedValue<Value>) -> Bool {
    if case .pending = value { return true }
    return false
}

private func recordedValue<Value: Sendable>(_ value: ProjectedValue<Value>) -> Value? {
    if case .value(let copied) = value { return copied }
    return nil
}

@Test(.timeLimit(.minutes(1)))
func RUN009_syncProjectionCapturesBeforeMatchingAndPublishesResultWithCompletion() async throws {
    let session = MockSession()
    let argumentGate = ProjectionPauseGate()
    let resultGate = ProjectionPauseGate()
    defer {
        argumentGate.resume()
        resultGate.resume()
    }
    let input = ProjectionPayload("request", text: "before projection")
    let response = ProjectionPayload("response", text: "before return")
    let stubs = SyncStubbing<ProjectionPayload, ProjectionPayload>()
    stubs.matching(Matcher { $0.read() == "changed after argument copy" }).willAnswer { input in
        input.set("changed in answer")
        return response
    }
    let projection = InvocationProjection<ProjectionPayload, ProjectionPayload, String, FrozenResponse>(
        argument: { input in
            let frozen = input.read()
            argumentGate.pause()
            return frozen
        },
        result: { response in
            let frozen = FrozenResponse(text: response.read())
            resultGate.pause()
            return frozen
        }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("projected"), configuration: stubs.finish(), projection: projection,
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let invocation = invokeOnDispatchWorker { endpoint.invoke(input) }

    await argumentGate.waitUntilEntered()
    let atAdmission = endpoint.projectedHistory()
    try #require(atAdmission.calls.count == 1)
    #expect(atAdmission.calls[0].phase == .admitted)
    #expect(isPending(atAdmission.calls[0].argument))
    #expect(isPending(atAdmission.calls[0].result))
    #expect(session.snapshot().activeInvocationCount == 1)
    input.set("changed after argument copy")
    argumentGate.resume()

    await resultGate.waitUntilEntered()
    let atResult = try #require(endpoint.projectedHistory().calls.first)
    #expect(atResult.phase == .admitted)
    #expect(recordedValue(atResult.argument) == "before projection")
    #expect(isPending(atResult.result))
    #expect(input.read() == "changed in answer")
    #expect(session.snapshot().events.map(\.phase) == [.admitted])
    response.set("changed after result copy")
    resultGate.resume()

    let raw = await invocation.value
    #expect(raw === response)
    #expect(raw.read() == "changed after result copy")
    let finalHistory = endpoint.projectedHistory()
    let final = try #require(finalHistory.calls.first)
    #expect(finalHistory.calls.count == 1)
    #expect(final.phase == .returned)
    #expect(final.epoch == finalHistory.epoch)
    #expect(final.sessionInvocationID == atResult.sessionInvocationID)
    #expect(recordedValue(final.argument) == "before projection")
    #expect(recordedValue(final.result) == FrozenResponse(text: "before return"))
    #expect(atAdmission.calls[0].phase == .admitted)
    #expect(isPending(atAdmission.calls[0].argument))
    #expect(isPending(atResult.result))
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned])
}

enum ProjectionPauseStage: Sendable {
    case argument
    case result
}

@Test(.timeLimit(.minutes(1)), arguments: [ProjectionPauseStage.argument, .result])
func RUN009_resetDropsPendingProjectionFromTheDetachedEpoch(_ stage: ProjectionPauseStage) async throws {
    let session = MockSession()
    let gate = ProjectionPauseGate()
    defer { gate.resume() }
    let stubs = SyncStubbing<ProjectionPayload, ProjectionPayload>()
    stubs.matching(.any).willAnswer { input in
        ProjectionPayload(input.label, text: "answer for " + input.label)
    }
    let projection = InvocationProjection<ProjectionPayload, ProjectionPayload, String, String>(
        argument: { input in
            if input.label == "old", stage == .argument { gate.pause() }
            return input.read()
        },
        result: { output in
            if output.label == "old", stage == .result { gate.pause() }
            return output.read()
        }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("reset-projection"), configuration: stubs.finish(), projection: projection,
        failureReporter: .swiftTesting, scope: session.makeMock()
    )
    let old = invokeOnDispatchWorker { endpoint.invoke(ProjectionPayload("old", text: "old payload")) }
    await gate.waitUntilEntered()
    let previous = try #require(endpoint.projectedHistory().calls.first)
    #expect(previous.phase == .admitted)
    if stage == .argument { #expect(isPending(previous.argument)) }
    else { #expect(isPending(previous.result)) }

    let nextEpoch = try session.resetHistory(.detachActive)
    #expect(nextEpoch != previous.epoch)
    #expect(endpoint.projectedHistory().epoch == nextEpoch)
    #expect(endpoint.projectedHistory().calls.isEmpty)
    #expect(endpoint.invoke(ProjectionPayload("fresh", text: "new payload")).read() == "answer for fresh")
    let fresh = try #require(endpoint.projectedHistory().calls.first)

    gate.resume()
    let oldResult = await old.value
    #expect(oldResult.read() == "answer for old")
    let retained = endpoint.projectedHistory()
    #expect(retained.epoch == nextEpoch)
    #expect(retained.calls.map(\.sessionInvocationID) == [fresh.sessionInvocationID])
    #expect(retained.calls.first?.phase == .returned)
    if let first = retained.calls.first {
        #expect(recordedValue(first.argument) == "new payload")
        #expect(recordedValue(first.result) == "answer for fresh")
    }
    let archived = try #require(session.snapshot(epoch: previous.epoch))
    #expect(archived.events.map(\.phase) == [.admitted, .returned])
    #expect(archived.events.map(\.invocationID) == [previous.sessionInvocationID, previous.sessionInvocationID])
}
