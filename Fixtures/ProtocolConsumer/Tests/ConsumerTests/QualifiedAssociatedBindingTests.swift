import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import ParentDomain
import Testing

@Test func GEN008_qualifiedParentBindsAssociatedTypeAcrossTargets() throws {
    let _: String.Type = AssociatedDirectoryFromDependencyMock.Element.self
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = AssociatedDirectoryFromDependencyMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }, session: session) { stubs in
        stubs.load(key: .equal("record")).willAnswer { "remote-" + $0 }
        stubs.save(.equal("remote-record")).willReturn(())
    }

    let selected: any AssociatedDirectoryFromDependency<String> = mock
    let client = DependencyBoundDirectoryClient(directory: selected)
    #expect(client.refresh(key: "record") == "remote-record")
    #expect(mock.verify.load(key: .equal("record"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.save(.equal("remote-record"), phase: .returned).wasCalled(.once).passed)

    let inherited: any ParentDomain.BoundParent<String> = mock
    inherited.note("unstubbed")
    #expect(mock.verify.note(.equal("unstubbed"), phase: .returned).wasCalled(.once).passed)

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    let expected = EndpointID("schema1|ConsumerDomain.AssociatedDirectoryFromDependency|note(_:Swift.String)->Void|Sendable")
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.endpoint == expected)
    #expect(issue.source.fileID == "ParentDomain/BoundParent.swift")
    #expect(issue.source.filePath == "BoundParent.swift")
    #expect(issue.source.line == 5)
    #expect(issue.source.column == 1)

    let snapshot = session.snapshot()
    let inheritedEvents = snapshot.events.filter { $0.endpoint == expected }
    #expect(inheritedEvents.map(\.phase) == [.admitted, .returned])
    #expect(Set(inheritedEvents.map(\.invocationID)).count == 1)
    #expect(snapshot.activeInvocationCount == 0)
}
