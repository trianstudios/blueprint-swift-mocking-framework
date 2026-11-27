import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct UnseenPackValue: Sendable, Equatable { let text: String }

private struct TypedEchoProvider: PackProviderDirectoryMockBehavior {
    let session: MockSession
    let observed: StoredProperty<[SessionSnapshot]>

    func echo<each Element: Sendable>(_ values: repeat each Element) -> (repeat each Element) {
        observed.set(observed.get() + [session.snapshot()])
        return (repeat each values)
    }
}

@Test func GEN021_generatedPackProviderPreservesTypedArgumentsAndIdentity() throws {
    let session = MockSession()
    let observed = StoredProperty<[SessionSnapshot]>([])
    let mock = PackProviderDirectoryMock(failureReporter: .swiftTesting, session: session,
        genericBehavior: TypedEchoProvider(session: session, observed: observed)
    ) { stubs in
        stubs.label(for: .any).willAnswer { "label/\($0)" }
    }
    let dependency: any PackProviderDirectory = mock
    let _: Void = dependency.echo()
    let unseen = UnseenPackValue(text: "new type")
    let one: UnseenPackValue = dependency.echo(unseen)
    let many: (String, Int, UnseenPackValue) = dependency.echo("text", 42, unseen)
    let tuple: (Int, String) = dependency.echo((10, "tuple"))
    let flat: (Int, String) = dependency.echo(10, "tuple")
    let _: Void = dependency.echo(())
    #expect(one == unseen)
    #expect(many.0 == "text" && many.1 == 42 && many.2 == unseen)
    #expect(tuple == flat)
    #expect(tuple.0 == 10 && tuple.1 == "tuple")

    let events = session.snapshot().events
    try #require(events.count == 12)
    let declaration = "schema1|ConsumerDomain.PackProviderDirectory|echo<each T:Swift.Sendable>(_:repeat each T)->(repeat each T)|Sendable"
    let types: [[Any.Type]] = [
        [], [UnseenPackValue.self], [String.self, Int.self, UnseenPackValue.self],
        [(Int, String).self], [Int.self, String.self], [Void.self]
    ]
    let endpoints = types.map { EndpointID(declaration, specializedForPack: $0) }
    #expect(endpoints[0] != endpoints[5])
    #expect(endpoints[3] != endpoints[4])
    #expect(endpoints[1] != EndpointID(declaration, specializedFor: UnseenPackValue.self))
    #expect(endpoints[4] != EndpointID(declaration, specializedForPack: [String.self, Int.self]))
    for (index, endpoint) in endpoints.enumerated() {
        let admission = events[index * 2]
        let terminal = events[index * 2 + 1]
        #expect(admission.phase == .admitted)
        #expect(terminal.phase == .returned)
        #expect(admission.endpoint == endpoint)
        #expect(terminal.endpoint == endpoint)
        #expect(terminal.invocationID == admission.invocationID)
    }
    #expect(Set(events.map(\.invocationID)).count == endpoints.count)
    #expect(observed.get().map(\.activeInvocationCount) == Array(repeating: 1, count: endpoints.count))
    #expect(session.snapshot().activeInvocationCount == 0)

    #expect(dependency.label(for: "ordinary") == "label/ordinary")
    #expect(mock.verify.label(for: .equal("ordinary"), phase: .returned).wasCalled(.once).passed)
}
