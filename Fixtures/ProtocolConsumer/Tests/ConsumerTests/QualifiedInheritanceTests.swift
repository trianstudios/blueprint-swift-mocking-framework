import Testing
import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import ParentDomain

@Test func GEN002_qualifiedParentsKeepModuleIdentityAndForeignDeclarationProvenance() throws {
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = QualifiedDirectoryMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }, session: session) { stubs in
        stubs.localLabel(for: .equal("local")).willReturn("local-label")
        stubs.remoteLabel(for: .equal(7)).willReturn("remote-label")
        stubs.status().willReturn(42)
        stubs.recordForeign(.equal("shared")).willReturn(())
    }

    let client = QualifiedDirectoryClient(directory: mock)
    let labels = client.labels(key: "local", code: 7)
    #expect(labels.local == "local-label")
    #expect(labels.remote == "remote-label")
    let directory: any QualifiedDirectory = mock
    #expect(directory.status() == 42)
    let local: any ConsumerDomain.SharedDirectory = mock
    let foreign: any ParentDomain.SharedDirectory = mock
    local.recordForeign("shared")
    foreign.recordForeign("shared")
    foreign.recordForeign("missing")

    #expect(mock.verify.localLabel(for: .equal("local"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.remoteLabel(for: .equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.status(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.recordForeign(.equal("shared"), phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.recordForeign(.equal("missing"), phase: .returned).wasCalled(.once).passed)

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.source.fileID == "ParentDomain/ForeignSharedDirectory.swift")
    #expect(issue.source.filePath == "ForeignSharedDirectory.swift")
    #expect(issue.source.line == 2)
    #expect(issue.source.column == 1)
    #expect(issue.endpoint.rawValue.hasPrefix("schema1|ConsumerDomain.QualifiedDirectory|recordForeign("))
    let events = session.snapshot().events.filter { $0.endpoint == issue.endpoint }
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned])
    #expect(Set(events.map(\.invocationID)).count == 3)
}
