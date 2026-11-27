import BlueprintMocking
import Foundation

private struct Order: Equatable, Sendable {
    let units: Int
}

private struct Quote: Encodable, Equatable, Sendable {
    let catalog: String
    let cents: Int
}

private protocol Pricing: Sendable {
    func quote(_ order: Order) -> Quote
}

private struct MockPricing: Pricing {
    let endpoint: SyncEndpoint<Order, Quote>

    init(catalog: String, centsPerUnit: Int) {
        let stubs = SyncStubbing<Order, Quote>()
        stubs.matching(.any).willAnswer { order in
            Quote(catalog: catalog, cents: centsPerUnit * order.units)
        }
        endpoint = SyncEndpoint(
            id: EndpointID("legacy.priceQuote"),
            configuration: stubs.finish(),
            failureReporter: FailureReporter { issue in fatalError(issue.message) }
        )
    }

    func quote(_ order: Order) -> Quote { endpoint.invoke(order) }
}

private enum LegacyPricing {
    static let registration = LegacyProcessRegistry<any Pricing>()

    // The legacy caller has no context parameter, session reference, or instance seam.
    static func quote(_ order: Order) throws(LegacyProcessRegistryError) -> Quote {
        try registration.current().quote(order)
    }
}

private enum FixtureFailure: Error {
    case usage
    case scopeWasStillActive
    case nestedScopeWasEntered
    case unexpectedTaskContext
    case interactiveGateFailed
    case wrongQuote
    case intentionalBodyFailure
}

private struct Evidence: Encodable {
    let clearedBefore: Bool
    let clearedAfterReturn: Bool
    let clearedAfterThrow: Bool
    let rejectedNestedScope: Bool
    let during: Quote
    let child: Int32
}

private struct Response: Encodable {
    let schema = 1
    let requestID: String
    let pid: Int32
    let result: Evidence
}

@main
struct LegacyProcessChild {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let centsPerUnit = Int(args[2]), let status = Int32(args[5]),
              let requestID = ProcessInfo.processInfo.environment["BLUEPRINT_LEGACY_REQUEST_ID"] else {
            throw FixtureFailure.usage
        }

        try requireCleared()
        let order = Order(units: 3)
        let mock = MockPricing(catalog: args[1], centsPerUnit: centsPerUnit)
        let quote = try await LegacyPricing.registration.withScope(mock) {
            do {
                try LegacyPricing.registration.withScope(mock) { () throws -> Void in
                    throw FixtureFailure.nestedScopeWasEntered
                }
                throw FixtureFailure.nestedScopeWasEntered
            } catch LegacyProcessRegistryError.scopeAlreadyActive {}

            try waitForRelease(ready: args[3], release: args[4])
            return try await Task.detached {
                guard MockSession.currentContext == nil else {
                    throw FixtureFailure.unexpectedTaskContext
                }
                return try LegacyPricing.quote(order)
            }.value
        }
        try requireCleared()
        guard quote == Quote(catalog: args[1], cents: centsPerUnit * order.units),
              mock.endpoint.verification(matching: .equal(order), phase: .returned).wasCalled(.once).passed
        else { throw FixtureFailure.wrongQuote }

        let replacement = MockPricing(catalog: "replacement", centsPerUnit: 1)
        do {
            try LegacyPricing.registration.withScope(replacement) { () throws -> Void in
                guard try LegacyPricing.quote(order) == Quote(catalog: "replacement", cents: order.units)
                else { throw FixtureFailure.wrongQuote }
                throw FixtureFailure.intentionalBodyFailure
            }
            throw FixtureFailure.wrongQuote
        } catch FixtureFailure.intentionalBodyFailure {}
        try requireCleared()

        let pid = ProcessInfo.processInfo.processIdentifier
        let evidence = Evidence(clearedBefore: true, clearedAfterReturn: true, clearedAfterThrow: true,
                                rejectedNestedScope: true, during: quote, child: pid)
        let response = try JSONEncoder().encode(Response(requestID: requestID, pid: pid, result: evidence))
        try FileHandle.standardOutput.write(contentsOf: response)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
        exit(status)
    }

    private static func requireCleared() throws {
        do {
            _ = try LegacyPricing.quote(Order(units: 1))
            throw FixtureFailure.scopeWasStillActive
        } catch LegacyProcessRegistryError.noActiveScope {}
    }

    private static func waitForRelease(ready: String, release: String) throws {
        let readyHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: ready))
        try readyHandle.write(contentsOf: Data([49]))
        try readyHandle.close()

        let releaseHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: release))
        defer { try? releaseHandle.close() }
        guard try releaseHandle.read(upToCount: 1) == Data([49]) else {
            throw FixtureFailure.interactiveGateFailed
        }
    }
}
