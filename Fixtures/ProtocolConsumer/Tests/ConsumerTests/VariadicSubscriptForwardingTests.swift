import Foundation
import Testing
import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

// The forwarding fixture protects its array-backed records with this lock.
private final class RecordingVariadicSubscriptForwarder: @unchecked Sendable {
    struct Address: Hashable {
        let field: String
        let indices: [Int]
    }

    struct Write: Equatable {
        let address: Address
        let value: String
    }

    struct Records {
        var values: [Address: String] = [:]
        var reads: [Address] = []
        var writes: [Write] = []
        var remoteReads: [Address] = []
        var issues: [MockIssue] = []
    }

    private let lock = NSLock()
    private var records = Records()

    func read(field: String, indices: [Int]) -> String {
        let address = Address(field: field, indices: indices)
        return withRecords {
            $0.reads.append(address)
            return $0.values[address] ?? (indices.isEmpty ? "empty" : "draft")
        }
    }

    func write(field: String, indices: [Int], value: String) {
        let address = Address(field: field, indices: indices)
        withRecords {
            $0.writes.append(Write(address: address, value: value))
            $0.values[address] = value
        }
    }

    func remote(region: String, indices: [Int]) async throws(VariadicSubscriptFailure) -> String {
        await Task.yield()
        withRecords { $0.remoteReads.append(Address(field: region, indices: indices)) }
        guard !indices.isEmpty else { throw .unavailable }
        return region + ":" + indices.map(String.init).joined(separator: ",")
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

@Test func GEN024_RUN018_variadicSubscriptForwardingPreservesAccessorEffects() async throws {
    let session = MockSession()
    let real = RecordingVariadicSubscriptForwarder()
    let mock = VariadicSubscriptDirectoryMock(
        failureReporter: FailureReporter { real.report($0) },
        session: session,
        forwarding: .init { forwarding in
            forwarding.get_subscript(field: String.self, [Int].self) { field, indices in
                real.read(field: field, indices: indices)
            }
            forwarding.set_subscript(field: String.self, [Int].self, newValue: String.self) { field, indices, value in
                real.write(field: field, indices: indices, value: value)
            }
            forwarding.get_subscript(remote: String.self, [Int].self) {
                (region, indices) async throws(VariadicSubscriptFailure) in
                try await real.remote(region: region, indices: indices)
            }
        }
    ) { stubs in
        stubs.get_subscript(field: .equal("stubbed"), .equal([9, 3, 9])).willReturn("explicit read")
        stubs.set_subscript(field: .equal("stubbed"), .equal([9, 3, 9]), newValue: .equal("explicit write"))
            .willReturn(())
    }
    var client = VariadicSubscriptClient(directory: mock)
    #expect(client.emptyLabel() == "empty")
    client.storeEmptyLabel()
    #expect(client.emptyLabel() == "inbox")

    let checkpoint = session.checkpoint()
    client.reviseOrderedLabel()
    let edit = try session.events(since: checkpoint)
    try #require(edit.count == 4)
    #expect(edit.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(edit[0].endpoint.rawValue.contains(".get"))
    #expect(edit[2].endpoint.rawValue.contains(".set"))
    #expect(edit[0].invocationID == edit[1].invocationID)
    #expect(edit[2].invocationID == edit[3].invocationID)
    #expect(edit[0].invocationID != edit[2].invocationID)

    var dependency: any VariadicSubscriptDirectory = mock
    #expect(dependency[field: "stubbed", 9, 3, 9] == "explicit read")
    dependency[field: "stubbed", 9, 3, 9] = "explicit write"
    let remote = try await client.remoteNames()
    #expect(remote == "east:6,3,6")
    do throws(VariadicSubscriptFailure) {
        _ = try await client.remoteWithoutIndices()
        Issue.record("Expected the forwarded getter to throw its declared error")
    } catch {
        #expect(error == .unavailable)
    }

    let records = real.snapshot()
    let empty = RecordingVariadicSubscriptForwarder.Address(field: "title", indices: [])
    let ordered = RecordingVariadicSubscriptForwarder.Address(field: "title", indices: [4, 2, 4])
    #expect(records.reads == [empty, empty, ordered])
    #expect(records.writes == [.init(address: empty, value: "inbox"), .init(address: ordered, value: "draft!")])
    #expect(records.values[ordered] == "draft!")
    #expect(records.remoteReads == [
        .init(field: "east", indices: [6, 3, 6]),
        .init(field: "east", indices: []),
    ])
    #expect(records.issues.isEmpty)

    #expect(mock.verify.get_subscript(field: .equal("title"), .equal([4, 2, 4]), phase: .returned)
        .wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(field: .equal("title"), .equal([4, 2, 4]), newValue: .equal("draft!"),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(field: .equal("stubbed"), .equal([9, 3, 9]), phase: .returned)
        .wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(field: .equal("stubbed"), .equal([9, 3, 9]), newValue: .equal("explicit write"),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(remote: .equal("east"), .equal([6, 3, 6]),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(remote: .equal("east"), .equal([]), phase: .threw).wasCalled(.once).passed)
}
