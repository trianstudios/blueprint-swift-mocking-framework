import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN024_GEN025_staticAndInstanceSubscriptWitnessesKeepSeparateHistories() throws {
    let session = MockSession()
    let mock = TypeSubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(.equal(7)).willReturn(10)
        stubs.set_subscript(.equal(7), newValue: .equal(110)).willReturn(())
    }
    let scope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(.equal(7)).willReturn(20)
        stubs.set_subscript(.equal(7), newValue: .equal(21)).willReturn(())
    }

    var instance: any TypeSubscriptDirectory = mock
    instance[7] += 100
    #expect(scope.verify.get_subscript(.equal(7)).wasCalled(.never).passed)
    #expect(scope.verify.set_subscript(.equal(7), newValue: .any).wasCalled(.never).passed)

    scope.withValue {
        TypeSubscriptClient.increment(7, by: 1, using: TypeSubscriptDirectoryMock.self)
    }

    #expect(mock.verify.get_subscript(.equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(.equal(7), newValue: .equal(110), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(.equal(7), newValue: .equal(21)).wasCalled(.never).passed)
    #expect(scope.verify.get_subscript(.equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(scope.verify.set_subscript(.equal(7), newValue: .equal(21), phase: .returned).wasCalled(.once).passed)
    #expect(scope.verify.set_subscript(.equal(7), newValue: .equal(110)).wasCalled(.never).passed)

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned,
                                    .admitted, .returned])
    let admissions = events.filter { $0.phase == .admitted }
    try #require(admissions.count == 4)
    #expect(Set(admissions.map(\.endpoint.rawValue)).count == 4)
    #expect(admissions[0].mockID == admissions[1].mockID)
    #expect(admissions[2].mockID == admissions[3].mockID)
    #expect(admissions[0].mockID != admissions[2].mockID)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func GEN025_concurrentTypeScopesIsolateTheSameMetatype(shareSession: Bool) async {
    let firstSession = MockSession()
    let secondSession = shareSession ? firstSession : MockSession()
    let first = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: .swiftTesting, session: firstSession) {
        $0.get_subscript(.equal(13)).willReturn(31)
    }
    let second = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: .swiftTesting, session: secondSession) {
        $0.get_subscript(.equal(13)).willReturn(47)
    }
    let (firstEntries, firstEntered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (secondEntries, secondEntered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    let firstTask = Task.detached {
        await first.withValue {
            firstEntered.yield(())
            var peer = secondEntries.makeAsyncIterator()
            _ = await peer.next()
            return await Task {
                TypeSubscriptClient.read(13, using: TypeSubscriptDirectoryMock.self)
            }.value
        }
    }
    let secondTask = Task.detached {
        await second.withValue {
            secondEntered.yield(())
            var peer = firstEntries.makeAsyncIterator()
            _ = await peer.next()
            return TypeSubscriptClient.read(13, using: TypeSubscriptDirectoryMock.self)
        }
    }

    let firstResult = await firstTask.value
    let secondResult = await secondTask.value
    #expect(firstResult == 31)
    #expect(secondResult == 47)
    #expect(first.verify.get_subscript(.equal(13), phase: .returned).wasCalled(.once).passed)
    #expect(second.verify.get_subscript(.equal(13), phase: .returned).wasCalled(.once).passed)

    let expectedCount = shareSession ? 2 : 1
    let firstReturns = firstSession.snapshot().events.filter { $0.phase == .returned }
    let secondReturns = secondSession.snapshot().events.filter { $0.phase == .returned }
    #expect(firstReturns.count == expectedCount)
    #expect(secondReturns.count == expectedCount)
    #expect(Set(firstReturns.map(\.mockID)).count == expectedCount)
    #expect(Set(secondReturns.map(\.mockID)).count == expectedCount)
}

@Test func GEN025_resetRejectsNewVerificationFromAnEarlierTypeScope() throws {
    let session = MockSession()
    let oldScope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: .swiftTesting, session: session) {
        $0.get_subscript(.equal(5)).willReturn(10)
    }
    let oldEpoch = session.snapshot().epoch
    #expect(oldScope.withValue { TypeSubscriptClient.read(5, using: TypeSubscriptDirectoryMock.self) } == 10)
    let beforeReset = oldScope.verify.get_subscript(.equal(5), phase: .returned).wasCalled(.once)
    #expect(beforeReset.passed)
    #expect(beforeReset.epoch == oldEpoch)

    let newEpoch = try session.resetHistory()
    #expect(newEpoch != oldEpoch)
    var staleResult: VerificationResult?
    withKnownIssue("A type scope from an earlier epoch must reject verification after reset") {
        staleResult = oldScope.verify.get_subscript(.equal(5)).wasCalled(.never)
    }
    let stale = try #require(staleResult)
    #expect(stale.isStale)
    #expect(!stale.passed)
    #expect(stale.epoch == oldEpoch)
    #expect(stale.invocationIDs.isEmpty)
    #expect(session.snapshot().events.isEmpty)

    let newScope = TypeSubscriptDirectoryMock.makeTypeScope(failureReporter: .swiftTesting, session: session) {
        $0.get_subscript(.equal(5)).willReturn(20)
    }
    let empty = newScope.verify.get_subscript(.equal(5)).wasCalled(.never)
    #expect(empty.passed)
    #expect(!empty.isStale)
    #expect(empty.epoch == newEpoch)

    #expect(newScope.withValue { TypeSubscriptClient.read(5, using: TypeSubscriptDirectoryMock.self) } == 20)
    let afterReset = newScope.verify.get_subscript(.equal(5), phase: .returned).wasCalled(.once)
    #expect(afterReset.passed)
    #expect(afterReset.epoch == newEpoch)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned])
}
