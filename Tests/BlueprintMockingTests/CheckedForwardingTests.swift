import Testing
@testable import BlueprintMocking

private enum ForwardingFailure: Error, Equatable {
    case fromReal(String)
    case missing
}

@Test func RUN018_checkedSyncUsesMatchingStubBeforeRealImplementation() {
    let session = MockSession()
    let calls = CriticalState<[String]>([])
    let setup = SyncStubbing<String, String>()
    setup.matching(.equal("stub")).willReturn("stub result")
    let endpoint = SyncEndpoint(
        id: EndpointID("spy.sync"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: { input in
            #expect(session.snapshot().activeInvocationCount == 1)
            calls.withLock { $0.append(input) }
            return "real " + input
        }
    )

    #expect(endpoint.invoke("stub") == "stub result")
    #expect(endpoint.invoke("miss") == "real miss")
    #expect(calls.withLock { $0 } == ["miss"])
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(2)).passed)
    #expect(endpoint.invocations.map(\.origin) == [nil, .forwarded])
    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.map(\.origin) == [nil, nil, nil, .forwarded])
    let expectedIDs = endpoint.invocations.flatMap { [$0.sessionInvocationID, $0.sessionInvocationID] }
    #expect(events.map(\.invocationID) == expectedIDs)
}

@Test func RUN018_checkedSyncThrowingPreservesTypedRealErrors() throws {
    let session = MockSession()
    let setup = SyncThrowingStubbing<String, String, ForwardingFailure>()
    setup.matching(.equal("stub")).willReturn("stub result")
    let endpoint = SyncThrowingEndpoint(
        id: EndpointID("spy.syncThrows"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: SyncThrowingForwarding { input throws(ForwardingFailure) in
            guard input != "broken" else { throw .fromReal(input) }
            return "real " + input
        }
    )

    #expect(try endpoint.invoke("stub") == "stub result")
    #expect(try endpoint.invoke("working") == "real working")
    do throws(ForwardingFailure) {
        _ = try endpoint.invoke("broken")
        Issue.record("Expected a typed real error")
    } catch {
        #expect(error == .fromReal("broken"))
    }
    #expect(endpoint.invocations.map(\.phase) == [.returned, .returned, .threw])
    #expect(session.snapshot().events.filter { $0.origin == .forwarded }.map(\.phase) == [.returned, .threw])
}

@Test func RUN018_checkedAsyncSettlesInItsOriginalEpochAfterRealForwarding() async throws {
    let session = MockSession()
    let epoch = session.snapshot().epoch
    let setup = AsyncStubbing<String, String>()
    setup.matching(.equal("stub")).willReturn("stub result")
    let endpoint = AsyncEndpoint(
        id: EndpointID("spy.async"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: { input in
            await Task.yield()
            do {
                _ = try session.resetHistory(.detachActive)
            } catch {
                Issue.record("Expected active forwarding to detach: \(error)")
            }
            return "real " + input
        }
    )

    #expect(await endpoint.invoke("stub") == "stub result")
    #expect(await endpoint.invoke("miss") == "real miss")
    let archived = try #require(session.snapshot(epoch: epoch))
    #expect(archived.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(archived.events.map(\.origin) == [nil, nil, nil, .forwarded])
    #expect(Set(archived.events.suffix(2).map(\.invocationID)).count == 1)
    #expect(archived.activeInvocationCount == 0)
    #expect(session.snapshot().events.isEmpty)
}

@Test func RUN018_checkedAsyncThrowingDoesNotForwardAnExhaustedWinner() async throws {
    let session = MockSession()
    let forwarded = CriticalState<[String]>([])
    let issues = CriticalState<[MockIssue.Kind]>([])
    let setup = AsyncThrowingStubbing<String, String, ForwardingFailure>()
    setup.matching(.equal("sequence")).willSequence(.returning("step"))
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("spy.asyncThrows"), configuration: setup.finish(),
        failureReporter: FailureReporter { issue in issues.withLock { $0.append(issue.kind) } },
        scope: session.makeMock(), forwarding: AsyncThrowingForwarding { input async throws(ForwardingFailure) in
            forwarded.withLock { $0.append(input) }
            await Task.yield()
            guard input != "broken" else { throw .fromReal(input) }
            return "real " + input
        }, failureMapping: { _ in .missing }
    )

    #expect(try await endpoint.invoke("sequence") == "step")
    do throws(ForwardingFailure) {
        _ = try await endpoint.invoke("sequence")
        Issue.record("Expected finite sequence exhaustion")
    } catch {
        #expect(error == .missing)
    }

    #expect(try await endpoint.invoke("working") == "real working")
    do throws(ForwardingFailure) {
        _ = try await endpoint.invoke("broken")
        Issue.record("Expected a typed real error")
    } catch {
        #expect(error == .fromReal("broken"))
    }
    #expect(forwarded.withLock { $0 } == ["working", "broken"])
    #expect(issues.withLock { $0 } == [.sequenceExhausted])
    #expect(endpoint.invocations.map(\.phase) == [.returned, .threw, .returned, .threw])
    #expect(endpoint.invocations.map(\.origin) == [nil, nil, .forwarded, .forwarded])
    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw, .admitted, .returned, .admitted, .threw])
    #expect(events.map(\.origin) == [nil, nil, nil, nil, nil, .forwarded, nil, .forwarded])
}

@Test func RUN018_legacyEndpointInitializerKeepsItsSignatureAndFallback() {
    let session = MockSession()
    let makeEndpoint = SyncEndpoint<String, String>.init(id:configuration:failureReporter:scope:fallback:)
    let setup = SyncStubbing<String, String>().finish()
    let endpoint = makeEndpoint(
        EndpointID("spy.legacy"), setup, FailureReporter { _ in }, session.makeMock(), { issue in
            #expect(issue.kind == .unexpectedCall)
            return "legacy fallback"
        }
    )

    #expect(endpoint.invoke("miss") == "legacy fallback")
    #expect(session.snapshot().events.map(\.origin) == [nil, nil])
}
