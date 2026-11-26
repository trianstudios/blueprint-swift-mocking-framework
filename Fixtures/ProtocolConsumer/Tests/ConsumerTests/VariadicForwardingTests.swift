import Foundation
import Testing
import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

// Every mutable record in this test seam is accessed through its lock.
private final class RecordingVariadicForwarder: @unchecked Sendable {
    struct NamesCall: Equatable {
        let region: String
        let ids: [Int]
        let fallback: String
    }

    struct Records {
        var samples: [[Int]] = []
        var names: [NamesCall] = []
        var issues: [MockIssue] = []
    }

    private let lock = NSLock()
    private var records = Records()

    func sample(_ entries: [Int]) -> [Int] {
        withRecords { $0.samples.append(entries) }
        return entries
    }

    func names(in region: String, ids: [Int], fallback: String) async throws(VariadicFailure) -> String {
        await Task.yield()
        withRecords { $0.names.append(NamesCall(region: region, ids: ids, fallback: fallback)) }
        if region == "offline" { throw .offline }
        return region + ":" + ids.map(String.init).joined(separator: ",") + ":" + fallback
    }

    func report(_ issue: MockIssue) {
        withRecords { $0.issues.append(issue) }
    }

    func snapshot() -> Records {
        withRecords { $0 }
    }

    private func withRecords<Value>(_ work: (inout Records) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return work(&records)
    }
}

@Test func GEN020_RUN018_variadicForwardingKeepsPackedArraysAndTypedEffects() async throws {
    let session = MockSession()
    let real = RecordingVariadicForwarder()
    let mock = VariadicDirectoryMock(
        failureReporter: FailureReporter { real.report($0) },
        session: session,
        forwarding: .init { forwarding in
            forwarding.sample([Int].self) { entries in
                real.sample(entries)
            }
            forwarding.names(in: String.self, ids: [Int].self, fallback: String.self) {
                (region, ids, fallback) async throws(VariadicFailure) in
                try await real.names(in: region, ids: ids, fallback: fallback)
            }
        }
    ) { stubs in
        stubs.sample(.equal([91, 91])).willReturn([-1])
        stubs.names(in: .equal("stubbed"), ids: .equal([4, 4]), fallback: .equal("fallback"))
            .willReturn("explicit answer")
    }
    let dependency: any VariadicDirectory = mock
    let client = VariadicClient(directory: dependency)
    let large = Array(0..<64)

    #expect(real.snapshot().samples.isEmpty)
    #expect(real.snapshot().names.isEmpty)
    #expect(mock.verify.sample(.any).wasCalled(.never).passed)

    #expect(client.emptySample() == [])
    #expect(client.orderedSample() == [7, 2, 7, 9])
    #expect(client.largeSample() == large)
    #expect(dependency.sample(91, 91) == [-1])
    let named = try await client.orderedNames()
    #expect(named == "north:3,1,3:default")
    do throws(VariadicFailure) {
        _ = try await client.missingNames()
        Issue.record("Expected the array forwarder to throw VariadicFailure.offline")
    } catch {
        #expect(error == .offline)
    }
    let overridden = try await dependency.names(in: "stubbed", ids: 4, 4, fallback: "fallback")
    #expect(overridden == "explicit answer")

    let records = real.snapshot()
    #expect(records.samples == [[], [7, 2, 7, 9], large])
    #expect(records.names == [
        .init(region: "north", ids: [3, 1, 3], fallback: "default"),
        .init(region: "offline", ids: [], fallback: "default"),
    ])
    #expect(records.issues.isEmpty)
    #expect(mock.verify.sample(.equal([]), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.sample(.equal([7, 2, 7, 9]), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.sample(.equal(large), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.sample(.equal([91, 91]), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.names(in: .equal("north"), ids: .equal([3, 1, 3]), fallback: .equal("default"),
                              phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.names(in: .equal("offline"), ids: .equal([]), fallback: .equal("default"),
                              phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.names(in: .equal("stubbed"), ids: .equal([4, 4]), fallback: .equal("fallback"),
                              phase: .returned).wasCalled(.once).passed)

    let events = session.snapshot().events
    #expect(events.map(\.phase) == [
        .admitted, .returned, .admitted, .returned, .admitted, .returned, .admitted, .returned,
        .admitted, .returned, .admitted, .threw, .admitted, .returned,
    ])
    let admittedIDs = events.filter { $0.phase == .admitted }.map(\.invocationID)
    let finishedIDs = events.filter { $0.phase != .admitted }.map(\.invocationID)
    #expect(admittedIDs == finishedIDs)
}

@Test func GEN020_exhaustedVariadicStubKeepsItsOwnFailureBehavior() async throws {
    let real = RecordingVariadicForwarder()
    let mock = VariadicDirectoryMock(
        failureReporter: FailureReporter { real.report($0) },
        failureMappings: .init { mappings in
            mappings.names(in: String.self, ids: [Int].self, fallback: String.self) { _ in .offline }
        },
        forwarding: .init { forwarding in
            forwarding.names(in: String.self, ids: [Int].self, fallback: String.self) {
                (region, ids, fallback) async throws(VariadicFailure) in
                try await real.names(in: region, ids: ids, fallback: fallback)
            }
        }
    ) { stubs in
        stubs.names(in: .any, ids: .equal([1]), fallback: .any)
            .willSequence(.returning("configured"))
    }

    #expect(try await mock.names(in: "region", ids: 1, fallback: "backup") == "configured")
    await #expect(throws: VariadicFailure.offline) {
        try await mock.names(in: "region", ids: 1, fallback: "backup")
    }
    let records = real.snapshot()
    #expect(records.names.isEmpty)
    #expect(records.issues.map(\.kind) == [.sequenceExhausted])
}

@Test func GEN020_projectedVariadicWitnessRecordsTheForwardedResult() {
    let session = MockSession()
    let real = RecordingVariadicForwarder()
    let mock = VariadicDirectoryProjectedMock(
        failureReporter: FailureReporter { real.report($0) },
        session: session,
        forwarding: .init { $0.sample([Int].self) { real.sample($0) } },
        projection1: InvocationProjection(
            argument: { (entries: [Int]) in entries.map(String.init).joined(separator: ",") },
            result: { (entries: [Int]) in entries.count }
        )
    ) { _ in }
    let dependency: any VariadicDirectory = mock

    #expect(dependency.sample(9, 2, 9) == [9, 2, 9])
    #expect(real.snapshot().samples == [[9, 2, 9]])
    #expect(real.snapshot().issues.isEmpty)
    #expect(mock.verify.history1.verify(.once, matchingArgument: .equal("9,2,9")).passed)
    #expect(mock.verify.history1.verify(.once, matchingResult: .equal(3)).passed)
}
