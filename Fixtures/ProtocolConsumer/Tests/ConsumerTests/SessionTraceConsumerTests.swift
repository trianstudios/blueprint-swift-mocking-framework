import Foundation
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test func DX027_generatedSessionExportsAnExplicitMetadataOnlyTrace() throws {
    let session = MockSession(clock: .manual)
    let mock = UserRepositoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.greeting(for: .any).willReturn("private result sentinel")
    }
    #expect(mock.greeting(for: "private argument sentinel") == "private result sentinel")
    let snapshot = session.snapshot()
    let trace = try snapshot.exportTraceJSON(maximumRecords: 1)
    let text = String(decoding: trace, as: UTF8.self)
    let json = try #require(JSONSerialization.jsonObject(with: trace) as? [String: Any])
    let records = try #require(json["records"] as? [[String: Any]])
    let omitted = try #require(json["omitted"] as? [String: Any])
    try #require(records.count == 1)
    #expect(json["schemaVersion"] as? Int == 1)
    #expect(json["payloads"] as? String == "omitted")
    #expect(json["prunedThrough"] == nil)
    #expect(records[0]["kind"] as? String == "returned")
    #expect(records[0]["endpoint"] as? String == snapshot.events.last?.endpoint.rawValue)
    #expect(omitted["count"] as? Int == 1)
    #expect(omitted["firstOrdinal"] as? String == "1")
    #expect(omitted["lastOrdinal"] as? String == "1")
    #expect(!text.contains("private argument sentinel"))
    #expect(!text.contains("private result sentinel"))
}
