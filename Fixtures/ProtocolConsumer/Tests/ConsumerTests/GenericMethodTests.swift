import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN010_genericMethodSeparatesIntAndStringSpecializations() throws {
    let session = MockSession()
    let mock = GenericMethodDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        let intRule: SyncStub<Int, Int> = stubs.transform(.equal(7), as: Int.self)
        let stringRule: SyncStub<String, String> = stubs.transform(.equal("7"), as: String.self)
        intRule.willAnswer { $0 + 10 }
        stringRule.willAnswer { "text-\($0)" }
    }
    let client = GenericMethodClient(directory: mock)

    #expect(client.transform(7) == 17)
    #expect(client.transform("7") == "text-7")
    #expect(mock.verify.transform(.equal(7), as: Int.self, phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.transform(.equal("7"), as: String.self, phase: .returned).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    try #require(snapshot.events.count == 4)
    #expect(snapshot.activeInvocationCount == 0)
    let intAdmission = snapshot.events[0]
    let intReturn = snapshot.events[1]
    let stringAdmission = snapshot.events[2]
    let stringReturn = snapshot.events[3]
    #expect(snapshot.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(intAdmission.invocationID == intReturn.invocationID)
    #expect(stringAdmission.invocationID == stringReturn.invocationID)
    #expect(intAdmission.invocationID != stringAdmission.invocationID)
    #expect(intAdmission.endpoint == intReturn.endpoint)
    #expect(stringAdmission.endpoint == stringReturn.endpoint)
    #expect(intAdmission.endpoint.rawValue == stringAdmission.endpoint.rawValue)
    #expect(intAdmission.endpoint != stringAdmission.endpoint)
    #expect(intAdmission.endpoint.specialization?.typeName == String(reflecting: Int.self))
    #expect(stringAdmission.endpoint.specialization?.typeName == String(reflecting: String.self))
}
