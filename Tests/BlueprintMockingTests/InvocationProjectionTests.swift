import Testing
@testable import BlueprintMocking

private typealias ProjectedReading = ProjectedInvocationHistory<Int, Int>

@Test func RUN040_projectionReadsPendingAdmissionWithoutHoldingAHistoryLock() throws {
    let session = MockSession()
    let read = CriticalState<(@Sendable () -> ProjectedReading)?>(nil)
    let argumentCall = CriticalState<ProjectedValue<Int>?>(nil)
    let resultCall = CriticalState<ProjectedValue<Int>?>(nil)
    let admittedPhase = CriticalState<CallPhase?>(nil)
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { "length " + String($0.count) }
    let projection = InvocationProjection<String, String, Int, Int>(
        argument: { input in
            let history = read.withLock { $0 }?()
            let pending = history?.calls.first?.argument
            argumentCall.withLock { $0 = pending }
            return input.count
        },
        result: { output in
            let history = read.withLock { $0 }?()
            let pending = history?.calls.first?.result
            let phase = history?.calls.first?.phase
            resultCall.withLock { $0 = pending }
            admittedPhase.withLock { $0 = phase }
            return output.count
        }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("search"), configuration: stubs.finish(), projection: projection,
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
    read.withLock { $0 = { endpoint.projectedHistory() } }
    defer { read.withLock { $0 = nil } }

    #expect(endpoint.invoke("secret") == "length 6")
    #expect(argumentCall.withLock { $0 } == .pending)
    #expect(resultCall.withLock { $0 } == .pending)
    #expect(admittedPhase.withLock { $0 } == .admitted)
    let history = endpoint.projectedHistory()
    let call = try #require(history.calls.first)
    #expect(call.argument == .value(6))
    #expect(call.result == .value(8))
    #expect(call.phase == .returned)
    #expect(call.epoch == history.epoch)
    #expect(call.id == history.watermark)
    #expect(session.snapshot().events.map(\.invocationID) == [call.sessionInvocationID, call.sessionInvocationID])
}

@Test func RUN040_resetDuringProjectionDoesNotResurrectOldTypedHistory() throws {
    let session = MockSession()
    let epoch = session.snapshot().epoch
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let projection = InvocationProjection<String, String, Int, Int>(
        argument: { value in
            _ = try! session.resetHistory(.detachActive)
            return value.count
        },
        result: { $0.count }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("reset"), configuration: stubs.finish(), projection: projection,
        failureReporter: FailureReporter { _ in }, scope: session.makeMock()
    )
    #expect(endpoint.invoke("abc") == "abc")
    #expect(endpoint.projectedHistory().calls.isEmpty)
    #expect(endpoint.projectedHistory().epoch != epoch)
    let old = try #require(session.snapshot(epoch: epoch))
    #expect(old.events.map(\.phase) == [.admitted, .returned])
    #expect(old.events.first?.invocationID == old.events.last?.invocationID)
}
