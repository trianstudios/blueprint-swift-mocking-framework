import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN019_generatedOrdinaryInoutWitnessWritesBackBeforeReturnAndThrow() throws {
    let session = MockSession()
    let mock = OrdinaryInoutDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.normalize(.equal(-2)).willAnswer { (value: inout Swift.Int) in
            value = 2
        }
        stubs.adjust(.equal(7)).willAnswer { (value: inout Swift.Int) throws(OrdinaryInoutFailure) in
            value *= 3
            return value + 100
        }
        stubs.adjust(.equal(8)).willAnswer { (value: inout Swift.Int) throws(OrdinaryInoutFailure) in
            value = 88
            throw .afterMutation
        }
    }
    let witness: any OrdinaryInoutDirectory = mock
    #expect(session.snapshot().events.isEmpty)

    var normalized = -2
    witness.normalize(&normalized)
    #expect(normalized == 2)

    var returned = 7
    #expect(try witness.adjust(&returned) == 121)
    #expect(returned == 21)

    var thrown = 8
    do throws(OrdinaryInoutFailure) {
        _ = try witness.adjust(&thrown)
        Issue.record("Expected OrdinaryInoutFailure.afterMutation")
    } catch {
        #expect(error == .afterMutation)
    }
    #expect(thrown == 88)

    #expect(mock.verify.normalize(.equal(-2), after: .equal(2), phase: .returned).wasCalled(.once).passed)
    let returnedCalls: Verification<InoutValues<Int>> = mock.verify.adjust(
        .equal(7), after: .equal(21), phase: .returned
    )
    let thrownCalls: Verification<InoutValues<Int>> = mock.verify.adjust(
        .equal(8), after: .equal(88), phase: .threw
    )
    #expect(returnedCalls.wasCalled(.once).passed)
    #expect(thrownCalls.wasCalled(.once).passed)
    #expect(mock.verify.adjust(.equal(8), after: .equal(8), phase: .threw).wasCalled(.never).passed)

    let completed = session.snapshot()
    #expect(completed.activeInvocationCount == 0)
    #expect(completed.events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .threw])
    let admissions = completed.events.filter { $0.phase == .admitted }.map(\.invocationID)
    let outcomes = completed.events.filter { $0.phase != .admitted }.map(\.invocationID)
    #expect(admissions == outcomes)
    #expect(Set(admissions).count == 3)
}
