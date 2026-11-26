import BlueprintMocking
import Testing

private final class MainActorSpyPayload {
    var value: String

    init(_ value: String) { self.value = value }
}

private enum MainActorSpyRuntimeFailure: Error { case unavailable, overridden }

@Test @MainActor func RUN018_mainActorNonthrowingForwardingPreservesLocalValuesAndStubPrecedence() async {
    let overridden = MainActorSpyPayload("overridden")
    let stub = MainActorSpyPayload("stub")
    let request = MainActorSpyPayload("real")
    let reporter = FailureReporter { Issue.record("Unexpected mock issue: \($0.message)") }

    let syncStubs = MainActorSyncStubbing<MainActorSpyPayload, MainActorSpyPayload>()
    syncStubs.matching(.identical(to: overridden)).willReturn(stub)
    let sync = MainActorSyncEndpoint(
        id: EndpointID("actor-spy-sync"), configuration: syncStubs.finish(), failureReporter: reporter,
        forwarding: { input in
            MainActor.preconditionIsolated()
            input.value += " sync"
            return input
        }
    )
    let asyncStubs = MainActorAsyncStubbing<MainActorSpyPayload, MainActorSpyPayload>()
    asyncStubs.matching(.identical(to: overridden)).willReturn(stub)
    let async = MainActorAsyncEndpoint(
        id: EndpointID("actor-spy-async"), configuration: asyncStubs.finish(), failureReporter: reporter,
        forwarding: { input in
            await Task.yield()
            MainActor.preconditionIsolated()
            input.value += " async"
            return input
        }
    )

    #expect(sync.invoke(overridden) === stub)
    #expect(await async.invoke(overridden) === stub)
    #expect(overridden.value == "overridden")
    #expect(sync.invoke(request) === request)
    #expect(await async.invoke(request) === request)
    #expect(request.value == "real sync async")
    #expect(sync.invocations.map(\.origin) == [nil, .forwarded])
    #expect(async.invocations.map(\.origin) == [nil, .forwarded])
    #expect(sync.verification(matching: .any, phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(async.verification(matching: .any, phase: .returned, origin: .forwarded).wasCalled(.once).passed)
}

@Test(.timeLimit(.minutes(1)))
@MainActor func RUN018_mainActorThrowingForwardingRecordsTerminalOriginAndExactErrors() async throws {
    let returned = MainActorSpyPayload("return")
    let failed = MainActorSpyPayload("fail")
    let overridden = MainActorSpyPayload("override")
    let reporter = FailureReporter { Issue.record("Unexpected mock issue: \($0.message)") }

    let syncStubs = MainActorSyncThrowingStubbing<MainActorSpyPayload, MainActorSpyPayload, MainActorSpyRuntimeFailure>()
    syncStubs.matching(.identical(to: overridden)).willThrow(.overridden)
    let sync = MainActorSyncThrowingEndpoint(
        id: EndpointID("actor-spy-sync-throwing"), configuration: syncStubs.finish(), failureReporter: reporter,
        forwarding: MainActorSyncThrowingForwarding { input throws(MainActorSpyRuntimeFailure) in
            if input === failed { throw .unavailable }
            return input
        }
    )
    #expect(try sync.invoke(returned) === returned)
    do {
        _ = try sync.invoke(failed)
        Issue.record("Expected forwarded failure")
    } catch {
        #expect(error == .unavailable)
    }
    do {
        _ = try sync.invoke(overridden)
        Issue.record("Expected the explicit stub failure")
    } catch {
        #expect(error == .overridden)
    }
    #expect(sync.invocations.map(\.phase) == [.returned, .threw, .threw])
    #expect(sync.invocations.map(\.origin) == [.forwarded, .forwarded, nil])
    #expect(sync.verification(matching: .any, phase: .threw, origin: .forwarded).wasCalled(.once).passed)

    let (entries, entered) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let asyncStubs = MainActorAsyncThrowingStubbing<MainActorSpyPayload, MainActorSpyPayload, MainActorSpyRuntimeFailure>()
    let async = MainActorAsyncThrowingEndpoint(
        id: EndpointID("actor-spy-async-throwing"), configuration: asyncStubs.finish(), failureReporter: reporter,
        forwarding: MainActorAsyncThrowingForwarding { input async throws(MainActorSpyRuntimeFailure) in
            if input === failed { throw .unavailable }
            entered.yield(())
            entered.finish()
            var gate = releases.makeAsyncIterator()
            _ = await gate.next()
            MainActor.preconditionIsolated()
            return input
        }
    )

    let running = Task { @MainActor in
        let actual = try await async.invoke(returned)
        #expect(actual === returned)
    }
    var entry = entries.makeAsyncIterator()
    _ = await entry.next()
    #expect(async.invocations.map(\.phase) == [.admitted])
    #expect(async.invocations.map(\.origin) == [nil])
    #expect(async.verification(matching: .any, origin: .forwarded).wasCalled(.never).passed)
    release.yield(())
    release.finish()
    try await running.value

    do {
        _ = try await async.invoke(failed)
        Issue.record("Expected forwarded async failure")
    } catch {
        #expect(error == .unavailable)
    }
    #expect(async.invocations.map(\.phase) == [.returned, .threw])
    #expect(async.invocations.map(\.origin) == [.forwarded, .forwarded])
    #expect(async.verification(matching: .any, phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(async.verification(matching: .any, phase: .threw, origin: .forwarded).wasCalled(.once).passed)
}
