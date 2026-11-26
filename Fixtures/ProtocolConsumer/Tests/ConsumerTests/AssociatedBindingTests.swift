import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN008_concretePrimaryAssociatedTypeBindingSurvivesConsumerCalls() throws {
    let _: String.Type = AssociatedDirectoryMock.Element.self
    let session = MockSession()
    let saved = StoredProperty<[String]>([])
    let mock = AssociatedDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.load(key: .equal("row")).willAnswer { key in "loaded-" + key }
        stubs.save(.equal("loaded-row")).willAnswer { value in
            saved.set(saved.get() + [value])
        }
    }

    #expect(mock.verify.load(key: .equal("row")).wasCalled(.never).passed)
    #expect(mock.verify.save(.equal("loaded-row")).wasCalled(.never).passed)
    let directory: any AssociatedDirectory<String> = mock
    let client = AssociatedDirectoryClient(directory: directory)
    #expect(client.refresh(key: "row") == "loaded-row")
    #expect(saved.get() == ["loaded-row"])
    #expect(mock.verify.load(key: .equal("row"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.save(.equal("loaded-row"), phase: .returned).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let events = snapshot.events
    try #require(events.count == 4)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events[0].invocationID == events[1].invocationID)
    #expect(events[2].invocationID == events[3].invocationID)
    #expect(events[0].endpoint != events[2].endpoint)
    #expect(snapshot.activeInvocationCount == 0)
}

@Test func GEN008_inheritedAssociatedRequirementKeepsItsDeclarationSource() throws {
    let issues = StoredProperty<[MockIssue]>([])
    let mock = AssociatedDirectoryMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }) { _ in }
    let directory: any AssociatedDirectory<String> = mock
    directory.discard("unused")

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.source.fileID == "ConsumerDomain/AssociatedDirectoryBase.swift")
    #expect(issue.source.filePath == "AssociatedDirectoryBase.swift")
    #expect(issue.source.line == 5)
    #expect(issue.source.column == 1)
    #expect(issue.endpoint.rawValue.hasPrefix("schema1|ConsumerDomain.AssociatedDirectory|discard("))
    #expect(mock.verify.discard(.equal("unused"), phase: .returned).wasCalled(.once).passed)
}
