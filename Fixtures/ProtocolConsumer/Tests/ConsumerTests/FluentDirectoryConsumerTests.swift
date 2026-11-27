import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN009_fluentSelfUsesTypedFactoryAndVerifiesOnInvokedMock() {
    let session = MockSession()
    let result = FluentDirectoryMock(failureReporter: .swiftTesting, session: session) { _ in }
    let mock = FluentDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        let factoryRule: SyncStub<String, FluentDirectoryMock> = stubs.next(id: .equal("generic"))
        factoryRule.willAnswer { _ in result }
        stubs.next(id: .equal("existential")).willReturn(result)
    }

    #expect(mock.verify.next(id: .any).wasCalled(.never).passed)
    let concrete: FluentDirectoryMock = nextDirectory(mock, id: "generic")
    #expect(concrete === result)
    let erased = nextErasedDirectory(mock, id: "existential")
    #expect((erased as? FluentDirectoryMock) === result)

    #expect(mock.verify.next(id: .equal("generic"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.next(id: .equal("existential"), phase: .returned).wasCalled(.once).passed)
    #expect(result.verify.next(id: .any).wasCalled(.never).passed)
    let history = session.snapshot()
    #expect(history.events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(history.events.allSatisfy {
        $0.endpoint.rawValue == "schema1|ConsumerDomain.FluentDirectory|next(id:String)->Self|Sendable"
    })
    #expect(history.activeInvocationCount == 0)
}
