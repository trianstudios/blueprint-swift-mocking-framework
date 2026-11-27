import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

private func makeOneShotDirectory(
    session: MockSession, captor: OneShotEscapingCallbackCaptor<Int, String>
) -> EscapingCallbackDirectoryMock {
    EscapingCallbackDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.register(id: .any).capturingCallbackOnce(into: captor).willReturn("captured")
    }
}

@Test(.timeLimit(.minutes(1)))
func RUN010_oneShotCaptureRejectsDuplicateWhileAcquiredAndFinishes() async throws {
    let session = MockSession()
    let captor = OneShotEscapingCallbackCaptor<Int, String>(session: session)
    let mock = makeOneShotDirectory(session: session, captor: captor)
    let received = StoredProperty<[Int]>([])
    let entered = AsyncStream<Bool>.makeStream()
    let completed = AsyncStream<Result<String, OneShotCallbackDeliveryError>>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }

    let registration = registerEscapingCallback(mock, id: "held") { input in
        received.set(received.get() + [input])
        if input == 17 {
            entered.continuation.yield(true)
            guard release.wait(timeout: .now() + .seconds(30)) == .success else {
                return "test gate timed out"
            }
        }
        return "delivered-\(input)"
    }
    #expect(registration == "captured")
    #expect(received.get().isEmpty)
    try #require(captor.captures.count == 1)
    let capture = try #require(captor.captures.first)
    let registered = session.snapshot()
    #expect(registered.events.map(\.phase) == [.admitted, .returned])

    DispatchQueue.global().async {
        defer {
            entered.continuation.finish()
            completed.continuation.finish()
        }
        do throws(OneShotCallbackDeliveryError) {
            let value = try capture.invoke(17)
            completed.continuation.yield(.success(value))
        } catch {
            completed.continuation.yield(.failure(error))
        }
    }
    var arrivals = entered.stream.makeAsyncIterator()
    let started = await arrivals.next()
    try #require(started == true)

    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try capture.invoke(29) }
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try capture.cancel() }
    #expect(received.get() == [17])
    #expect(session.snapshot() == registered)

    let finished = try session.finishIfQuiescent()
    #expect(finished.isFinished)
    #expect(finished.activeInvocationCount == 0)
    #expect(finished.events == registered.events)
    #expect(captor.captures.isEmpty)
    #expect(throws: OneShotCallbackDeliveryError.finished) { try capture.invoke(31) }
    #expect(throws: OneShotCallbackDeliveryError.finished) { try capture.cancel() }

    release.signal()
    var outcomes = completed.stream.makeAsyncIterator()
    let outcome = await outcomes.next()
    let delivered = try #require(outcome)
    #expect(try delivered.get() == "delivered-17")
    #expect(received.get() == [17])
    #expect(session.snapshot() == finished)
    #expect(mock.verify.register(id: .equal("held"), phase: .returned).wasCalled(.once).passed)
}

@Test(.timeLimit(.minutes(1)))
func RUN010_oneShotCancellationRetiresOnlyItsPendingCapture() throws {
    let session = MockSession()
    let captor = OneShotEscapingCallbackCaptor<Int, String>(session: session)
    let mock = makeOneShotDirectory(session: session, captor: captor)
    let received = StoredProperty<[String]>([])

    for label in ["cancelled", "kept"] {
        let answer = registerEscapingCallback(mock, id: "same") { input in
            let value = "\(label)-\(input)"
            received.set(received.get() + [value])
            return value
        }
        #expect(answer == "captured")
    }
    let captures = captor.captures
    try #require(captures.count == 2)
    let registered = session.snapshot()

    try captures[0].cancel()
    #expect(throws: OneShotCallbackDeliveryError.cancelled) { try captures[0].cancel() }
    #expect(throws: OneShotCallbackDeliveryError.cancelled) { try captures[0].invoke(23) }
    #expect(received.get().isEmpty)

    #expect(try captures[1].invoke(23) == "kept-23")
    #expect(throws: OneShotCallbackDeliveryError.alreadyAcquired) { try captures[1].invoke(23) }
    #expect(received.get() == ["kept-23"])
    #expect(session.snapshot() == registered)
    #expect(mock.verify.register(id: .equal("same"), phase: .returned).wasCalled(.exactly(2)).passed)
}

@Test(.timeLimit(.minutes(1)))
func RUN010_oneShotCaptureResetInvalidatesEarlierEpoch() throws {
    let session = MockSession()
    let captor = OneShotEscapingCallbackCaptor<Int, String>(session: session)
    let mock = makeOneShotDirectory(session: session, captor: captor)
    let received = StoredProperty<[String]>([])

    func register(_ label: String) -> String {
        registerEscapingCallback(mock, id: "same") { input in
            let value = "\(label)-\(input)"
            received.set(received.get() + [value])
            return value
        }
    }

    #expect(register("old") == "captured")
    let old = try #require(captor.captures.first)
    let oldEpoch = session.snapshot().epoch
    let current = try session.resetHistory()
    #expect(current != oldEpoch)
    #expect(captor.captures.isEmpty)
    #expect(throws: OneShotCallbackDeliveryError.unavailable) { try old.invoke(7) }
    #expect(throws: OneShotCallbackDeliveryError.unavailable) { try old.cancel() }
    #expect(received.get().isEmpty)

    #expect(register("fresh") == "captured")
    let fresh = try #require(captor.captures.first)
    let currentHistory = session.snapshot()
    #expect(throws: OneShotCallbackDeliveryError.unavailable) { try old.invoke(7) }
    #expect(try fresh.invoke(7) == "fresh-7")
    #expect(received.get() == ["fresh-7"])
    #expect(currentHistory.epoch == current)
    #expect(session.snapshot() == currentHistory)
    #expect(mock.verify.register(id: .equal("same"), phase: .returned).wasCalled(.once).passed)

    let finished = try session.finishIfQuiescent()
    #expect(throws: OneShotCallbackDeliveryError.unavailable) { try old.cancel() }
    #expect(throws: OneShotCallbackDeliveryError.finished) { try fresh.invoke(11) }
    #expect(session.snapshot() == finished)
}
