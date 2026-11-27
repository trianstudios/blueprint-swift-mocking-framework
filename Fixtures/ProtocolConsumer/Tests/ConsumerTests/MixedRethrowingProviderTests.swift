import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct MixedRethrowsProvider: MixedRethrowingDirectoryMockRethrowsBehavior {
    func apply(
        prefix: String, _ primary: (Int) throws -> String,
        fallback: (String) throws -> Int, offset: Int
    ) rethrows -> String {
        let first = try primary(offset)
        let second = try fallback("\(prefix)/\(first)")
        return "\(prefix)/\(first)/\(second + offset)"
    }

    func applyAsync(
        _ input: Int, using callback: @Sendable (Int) async throws -> String, prefix: String
    ) async rethrows -> String {
        "\(prefix)/\(try await callback(input))"
    }
}

private enum MixedRethrowsObservation: Equatable {
    case primary(Int)
    case fallback(String)
}

private final class MixedRethrowsLocalPayload {
    let value = "local"
}

private final class MixedRethrowsPrimaryError: Error {}
private final class MixedRethrowsFallbackError: Error {}
private final class MixedAsyncRethrowsError: Error {}

@Test
@MainActor
func GEN015_RUN005_mixedRethrowsPreservesOrdinaryArgumentsAndBothErrors() throws {
    let session = MockSession()
    let mock = MixedRethrowingDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: MixedRethrowsProvider()
    )
    let directory: any MixedRethrowingDirectory = mock
    var observed: [MixedRethrowsObservation] = []
    weak var observedPayload: MixedRethrowsLocalPayload?

    func applyWithLocalPayload() -> String {
        let payload = MixedRethrowsLocalPayload()
        observedPayload = payload
        return directory.apply(prefix: "blue", { input in
            MainActor.preconditionIsolated()
            observed.append(.primary(input))
            return "\(payload.value)-\(input)"
        }, fallback: { input in
            MainActor.preconditionIsolated()
            observed.append(.fallback(input))
            return 71
        }, offset: 23)
    }

    #expect(applyWithLocalPayload() == "blue/local-23/94")
    #expect(observed == [.primary(23), .fallback("blue/local-23")])
    #expect(observedPayload == nil)

    observed.removeAll()
    let primaryError = MixedRethrowsPrimaryError()
    do {
        _ = try directory.apply(prefix: "skip", { (input: Int) throws(MixedRethrowsPrimaryError) -> String in
            observed.append(.primary(input))
            throw primaryError
        }, fallback: { input in
            observed.append(.fallback(input))
            return -1
        }, offset: -5)
        Issue.record("Expected the original primary error")
    } catch {
        #expect((error as? MixedRethrowsPrimaryError) === primaryError)
    }
    #expect(observed == [.primary(-5)])

    observed.removeAll()
    let fallbackError = MixedRethrowsFallbackError()
    do {
        _ = try directory.apply(prefix: "green", { input in
            observed.append(.primary(input))
            return "first-\(input)"
        }, fallback: { (input: String) throws(MixedRethrowsFallbackError) -> Int in
            observed.append(.fallback(input))
            throw fallbackError
        }, offset: 13)
        Issue.record("Expected the original fallback error")
    } catch {
        #expect((error as? MixedRethrowsFallbackError) === fallbackError)
    }
    #expect(observed == [.primary(13), .fallback("green/first-13")])

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 6)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw, .admitted, .threw])
    let identity = events[0].endpoint.rawValue
    #expect(identity.contains("ConsumerDomain.MixedRethrowingDirectory|apply(prefix:"))
    #expect(identity.contains("prefix:String") || identity.contains("prefix:Swift.String"))
    #expect(identity.contains("fallback:"))
    #expect(identity.contains("offset:Int") || identity.contains("offset:Swift.Int"))
    #expect(identity.contains(" rethrows"))
    #expect(events.allSatisfy { $0.endpoint == events[0].endpoint })
    let admissions = events.filter { $0.phase == .admitted }
    let terminals = events.filter { $0.phase != .admitted }
    #expect(Set(admissions.map(\.invocationID)).count == 3)
    #expect(admissions.map(\.invocationID) == terminals.map(\.invocationID))
}

@Test func GEN015_RUN005_mixedAsyncRethrowsPreservesOrdinaryArgumentsAndError() async throws {
    let session = MockSession()
    let mock = MixedRethrowingDirectoryMock(
        failureReporter: .swiftTesting, session: session, rethrowsBehavior: MixedRethrowsProvider()
    )
    let directory: any MixedRethrowingDirectory = mock
    let inputs = StoredProperty<[Int]>([])

    let returned = await directory.applyAsync(31, using: { input in
        await Task.yield()
        inputs.set(inputs.get() + [input])
        return "answer-\(input)"
    }, prefix: "blue")
    #expect(returned == "blue/answer-31")

    let expected = MixedAsyncRethrowsError()
    let throwing: @Sendable (Int) async throws(MixedAsyncRethrowsError) -> String = {
        input async throws(MixedAsyncRethrowsError) in
        inputs.set(inputs.get() + [input])
        throw expected
    }
    do {
        _ = try await directory.applyAsync(37, using: throwing, prefix: "green")
        Issue.record("Expected the original async callback error")
    } catch {
        #expect((error as? MixedAsyncRethrowsError) === expected)
    }
    #expect(inputs.get() == [31, 37])

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 4)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .threw])
    let identity = events[0].endpoint.rawValue
    #expect(identity.contains("ConsumerDomain.MixedRethrowingDirectory|applyAsync("))
    #expect(identity.contains("using:"))
    #expect(identity.contains("prefix:String") || identity.contains("prefix:Swift.String"))
    #expect(identity.contains(" async rethrows"))
    #expect(events.allSatisfy { $0.endpoint == events[0].endpoint })
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
}
