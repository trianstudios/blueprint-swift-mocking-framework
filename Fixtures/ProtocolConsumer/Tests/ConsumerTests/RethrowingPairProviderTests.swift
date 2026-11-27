import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct PairRethrowsProvider: RethrowingPairDirectoryMockRethrowsBehavior {
    func apply(_ primary: (Int) throws -> String, fallback: (String) throws -> Int) rethrows -> String {
        let first = try primary(37)
        let second = try fallback("fallback/\(first)")
        return "\(first):\(second)"
    }
}

private enum PairCallbackObservation: Equatable {
    case primary(Int)
    case fallback(String)
}

private final class PairPrimaryError: Error {}
private final class PairFallbackError: Error {}

@Test func GEN015_RUN005_generatedRethrowsPairPreservesEitherCallbackError() throws {
    let session = MockSession()
    let mock = RethrowingPairDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: PairRethrowsProvider()
    )
    let directory: any RethrowingPairDirectory = mock
    var observed: [PairCallbackObservation] = []

    let value = directory.apply({ input in
        observed.append(.primary(input))
        return "first-\(input)"
    }, fallback: { input in
        observed.append(.fallback(input))
        return 71
    })
    #expect(value == "first-37:71")
    #expect(observed == [.primary(37), .fallback("fallback/first-37")])

    observed.removeAll()
    let primaryError = PairPrimaryError()
    do {
        _ = try directory.apply({ (input: Int) throws(PairPrimaryError) -> String in
            observed.append(.primary(input))
            throw primaryError
        }, fallback: { input in
            observed.append(.fallback(input))
            return 0
        })
        Issue.record("Expected the primary callback's original error")
    } catch {
        #expect((error as? PairPrimaryError) === primaryError)
    }
    #expect(observed == [.primary(37)])

    observed.removeAll()
    let fallbackError = PairFallbackError()
    do {
        _ = try directory.apply({ input in
            observed.append(.primary(input))
            return "before-fallback-\(input)"
        }, fallback: { (input: String) throws(PairFallbackError) -> Int in
            observed.append(.fallback(input))
            throw fallbackError
        })
        Issue.record("Expected the fallback callback's original error")
    } catch {
        #expect((error as? PairFallbackError) === fallbackError)
    }
    #expect(observed == [.primary(37), .fallback("fallback/before-fallback-37")])

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 6)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw, .admitted, .threw])
    let endpoint = events[0].endpoint
    #expect(endpoint.rawValue.contains("ConsumerDomain.RethrowingPairDirectory|apply("))
    #expect(endpoint.rawValue.contains("fallback:"))
    #expect(endpoint.rawValue.contains(" rethrows"))
    #expect(events.allSatisfy { $0.endpoint == endpoint && $0.mockID == events[0].mockID })
    let admissions = events.filter { $0.phase == .admitted }
    let outcomes = events.filter { $0.phase != .admitted }
    #expect(Set(admissions.map(\.invocationID)).count == 3)
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
}
