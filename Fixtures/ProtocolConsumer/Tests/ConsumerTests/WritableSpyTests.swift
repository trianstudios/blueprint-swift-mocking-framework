import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct RealWritableSpyDirectory: WritableSpyDirectory {
    private let titleStorage = StoredProperty("draft")
    private let scores = [2: StoredProperty(10), 8: StoredProperty(30)]

    var title: String {
        get { titleStorage.get() }
        nonmutating set { titleStorage.set(newValue) }
    }

    subscript(slot slot: Int) -> Int {
        get { scores[slot]?.get() ?? -1 }
        nonmutating set { scores[slot]?.set(newValue) }
    }
}

@Test func RUN018_nonmutatingWritableSpyForwardsWritebackAndHonorsSetterStubs() {
    let session = MockSession()
    let real = RealWritableSpyDirectory()
    let mock = WritableSpyDirectoryMock(
        failureReporter: .swiftTesting, session: session, forwardingTo: real
    ) { stubs in
        stubs.set_title(.equal("blocked")).willReturn(())
        stubs.set_subscript(slot: .equal(2), newValue: .equal(900)).willReturn(())
    }
    let client = WritableSpyClient(directory: mock)

    client.appendToTitle("!")
    client.increaseScore(in: 2, by: 5)
    client.rename(to: "blocked")
    client.setScore(900, in: 2)
    client.setScore(900, in: 8)

    #expect(real.title == "draft!")
    #expect(real[slot: 2] == 15)
    #expect(real[slot: 8] == 900)
    #expect(mock.verify.get_title(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_title(.equal("draft!"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_title(.equal("blocked"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(slot: .equal(2), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(slot: .equal(2), newValue: .equal(15),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(slot: .equal(2), newValue: .equal(900),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_subscript(slot: .equal(8), newValue: .equal(900),
                                     phase: .returned).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let admissions = snapshot.events.filter { $0.phase == .admitted }
    let outcomes = snapshot.events.filter { $0.phase != .admitted }
    #expect(snapshot.events.count == 14)
    #expect(snapshot.activeInvocationCount == 0)
    #expect(admissions.allSatisfy { $0.origin == nil })
    #expect(outcomes.allSatisfy { $0.phase == .returned })
    #expect(admissions.map(\.invocationID) == outcomes.map(\.invocationID))
    #expect(Set(admissions.map(\.invocationID)).count == 7)
    #expect(outcomes.map { $0.origin == .forwarded } == [true, true, true, true, false, false, true])
    #expect(outcomes.map(\.endpoint.rawValue) == [
        "schema1|ConsumerDomain.WritableSpyDirectory|property:title.get->String|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|property:title.set(_:String)->Void|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|subscript:(slot:Int).get->Int|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|subscript:(slot:Int).set(slot:Int,newValue:Int)->Void|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|property:title.set(_:String)->Void|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|subscript:(slot:Int).set(slot:Int,newValue:Int)->Void|Sendable",
        "schema1|ConsumerDomain.WritableSpyDirectory|subscript:(slot:Int).set(slot:Int,newValue:Int)->Void|Sendable",
    ])
}
