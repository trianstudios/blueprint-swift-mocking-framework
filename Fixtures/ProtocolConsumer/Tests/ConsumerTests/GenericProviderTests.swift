import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct UnseenProviderValue: Hashable, Sendable {
    let name: String
}

private struct IdentityProvider: GenericProviderDirectoryMockBehavior {
    let session: MockSession
    let observed: StoredProperty<[SessionSnapshot]>

    func transform<T: Hashable & Sendable>(_ value: T) -> T {
        observed.set(observed.get() + [session.snapshot()])
        return value
    }
}

@Test func GEN011_polymorphicProviderKeepsUnseenValuesTypedAndRecordsSessionMetadata() throws {
    let session = MockSession()
    let empty = session.snapshot()
    let observed = StoredProperty<[SessionSnapshot]>([])
    let labelAnswers = StoredProperty(0)

    let mock = GenericProviderDirectoryMock(
        failureReporter: .swiftTesting,
        session: session,
        genericBehavior: IdentityProvider(session: session, observed: observed)
    ) { stubs in
        stubs.label(for: .equal("row")).willAnswer { value in
            labelAnswers.set(labelAnswers.get() + 1)
            return "label-\(value)"
        }
    }
    let dependency: any GenericProviderDirectory = mock
    #expect(mock.verify.label(for: .any).wasCalled(.never).passed)
    #expect(session.snapshot() == empty)
    #expect(observed.get().isEmpty)
    #expect(labelAnswers.get() == 0)

    let unseen = UnseenProviderValue(name: "new type")
    let transformedUnseen: UnseenProviderValue = dependency.transform(unseen)
    let transformedInt: Int = dependency.transform(7)
    #expect(transformedUnseen == unseen)
    #expect(transformedInt == 7)
    #expect(labelAnswers.get() == 0)

    let calls = session.snapshot()
    try #require(calls.events.count == 4)
    #expect(calls.activeInvocationCount == 0)
    let events = calls.events
    let identity = "schema1|ConsumerDomain.GenericProviderDirectory|transform<T:Swift.Hashable&Swift.Sendable>(_:T)->T|Sendable"
    let unseenEndpoint = EndpointID(identity, specializedFor: UnseenProviderValue.self)
    let intEndpoint = EndpointID(identity, specializedFor: Int.self)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.map(\.endpoint) == [unseenEndpoint, unseenEndpoint, intEndpoint, intEndpoint])
    #expect(unseenEndpoint != intEndpoint)
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].invocationID != events[2].invocationID)
    #expect(Set(events.map(\.mockID)).count == 1)

    let insideProvider = observed.get()
    try #require(insideProvider.count == 2)
    #expect(insideProvider.map(\.activeInvocationCount) == [1, 1])
    #expect(insideProvider[0].events == Array(events.prefix(1)))
    #expect(insideProvider[1].events == Array(events.prefix(3)))

    #expect(dependency.label(for: "row") == "label-row")
    #expect(labelAnswers.get() == 1)
    #expect(observed.get().count == 2)
    #expect(mock.verify.label(for: .equal("row"), phase: .returned).wasCalled(.once).passed)
}
