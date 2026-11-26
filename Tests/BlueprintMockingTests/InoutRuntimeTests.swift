import Testing
@testable import BlueprintMocking

private enum InoutTestFailure: Error, Equatable {
    case real(Int)
    case stub(Int)
}

@Test func GEN019_stubsMatchBeforeAndOverrideRealInoutMutation() {
    let session = MockSession()
    let realCount = CriticalState(0)
    let setup = InoutSyncStubbing<Int, String>()
    setup.matching(.equal(3)).willAnswer { value in
        value += 4
        return "stub"
    }
    let endpoint = InoutSyncEndpoint(
        id: EndpointID("inout.sync"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: { value in
            #expect(session.snapshot().activeInvocationCount == 1)
            realCount.withLock { $0 += 1 }
            value *= 2
            return "real"
        }
    )
    var stubbed = 3
    #expect(endpoint.invoke(&stubbed) == "stub")
    #expect(stubbed == 7)
    var forwarded = 4
    #expect(endpoint.invoke(&forwarded) == "real")
    #expect(forwarded == 8)
    #expect(realCount.withLock { $0 } == 1)
    #expect(endpoint.invocations.map(\.input.before) == [3, 4])
    #expect(endpoint.invocations.map(\.input.after) == [7, 8])
    #expect(endpoint.verification(matching: .equal(3), after: .equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(endpoint.verification(matching: .equal(4), after: .equal(8), origin: .forwarded).wasCalled(.once).passed)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(session.snapshot().events.map(\.origin) == [nil, nil, nil, .forwarded])
}

@Test func GEN019_typedThrowWritesBackStubAndRealMutationsAndSettlesOnce() {
    let session = MockSession()
    let setup = InoutSyncThrowingStubbing<Int, String, InoutTestFailure>()
    setup.matching(.equal(1)).willAnswer { value throws(InoutTestFailure) in
        value = 17
        throw .stub(value)
    }
    let endpoint = InoutSyncThrowingEndpoint(
        id: EndpointID("inout.typedThrows"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock(),
        forwarding: InoutSyncThrowingForwarding { value throws(InoutTestFailure) in
            #expect(session.snapshot().events.last?.phase == .admitted)
            value = 23
            throw .real(value)
        }
    )

    var stubbed = 1
    do throws(InoutTestFailure) {
        _ = try endpoint.invoke(&stubbed)
        Issue.record("Expected the stub's typed error")
    } catch {
        #expect(error == .stub(17))
    }
    #expect(stubbed == 17)
    var forwarded = 2
    do throws(InoutTestFailure) {
        _ = try endpoint.invoke(&forwarded)
        Issue.record("Expected the real implementation's typed error")
    } catch {
        #expect(error == .real(23))
    }
    #expect(forwarded == 23)
    #expect(endpoint.invocations.map(\.phase) == [.threw, .threw])
    #expect(endpoint.invocations.map(\.input.before) == [1, 2])
    #expect(endpoint.invocations.map(\.input.after) == [17, 23])
    #expect(endpoint.verification(matching: .equal(2), after: .equal(23), phase: .threw,
                                  origin: .forwarded).wasCalled(.once).passed)
    let snapshot = session.snapshot()
    #expect(snapshot.activeInvocationCount == 0)
    #expect(snapshot.events.map(\.phase) == [.admitted, .threw, .admitted, .threw])
    #expect(snapshot.events.map(\.origin) == [nil, nil, nil, .forwarded])
    let expectedIDs = endpoint.invocations.flatMap { [$0.sessionInvocationID, $0.sessionInvocationID] }
    #expect(snapshot.events.map(\.invocationID) == expectedIDs)
}

@Test func GEN019_afterDistinguishesCompletedOptionalNilFromPending() {
    let session = MockSession()
    let midflight = CriticalState<InoutSyncEndpoint<Int?, Void>?>(nil)
    let setup = InoutSyncStubbing<Int?, Void>()
    setup.matching(.any).willAnswer { value in
        let captured = midflight.withLock { $0 }
        #expect(captured?.invocations.first?.input.after == nil)
        #expect(captured?.verification(matching: .any, after: .equal(nil)).wasCalled(.never).passed == true)
        value = nil
    }
    let endpoint = InoutSyncEndpoint(
        id: EndpointID("inout.optional"), configuration: setup.finish(),
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, scope: session.makeMock()
    )
    midflight.withLock { $0 = endpoint }
    defer { midflight.withLock { $0 = nil } }

    var value: Int? = 7
    endpoint.invoke(&value)
    #expect(value == nil)
    #expect(endpoint.invocations.first?.input.after == .some(nil))
    #expect(endpoint.verification(matching: .equal(7), after: .equal(nil)).wasCalled(.once).passed)
}
