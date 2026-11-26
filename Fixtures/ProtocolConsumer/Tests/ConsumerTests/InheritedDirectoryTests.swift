import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN002_diamondBranchesShareOneTypedWitnessAndEndpoint() async throws {
    let session = MockSession()
    let mock = InheritedDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.label(for: .equal("record")).willAnswer { "shared-" + $0 }
        stubs.fetch(id: .equal(7)).willReturn("retrieved")
        stubs.fetch(id: .equal(8)).willThrow(.offline)
        stubs.get_revision().willReturn(3)
        stubs.rename(to: .equal("new")).willReturn("renamed")
        stubs.identify().willReturn("directory")
    }
    let client = InheritedDirectoryClient(directory: mock)
    let labels = client.labels(for: "record")
    #expect(labels.read == "shared-record")
    #expect(labels.write == "shared-record")

    let reader: any InheritedDirectoryReadBranch = mock
    let writer: any InheritedDirectoryWriteBranch = mock
    let inherited: any InheritedDirectory = mock
    #expect(reader.revision == 3)
    #expect(writer.rename(to: "new") == "renamed")
    #expect(inherited.identify() == "directory")
    #expect(try await reader.fetch(id: 7) == "retrieved")
    await #expect(throws: InheritedDirectoryFailure.offline) { try await writer.fetch(id: 8) }

    #expect(mock.verify.label(for: .equal("record"), phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.get_revision(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.rename(to: .equal("new"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.identify(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal(7), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.fetch(id: .equal(8), phase: .threw).wasCalled(.once).passed)

    let snapshot = session.snapshot()
    let shared = EndpointID("schema1|ConsumerDomain.InheritedDirectory|label(for:String)->String|Sendable")
    let events = snapshot.events.filter { $0.endpoint == shared }
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.filter { $0.phase == .admitted }.map(\.invocationID)
            == events.filter { $0.phase == .returned }.map(\.invocationID))
    #expect(Set(events.map(\.invocationID)).count == 2)
    #expect(Set(events.map(\.mockID)).count == 1)
    #expect(snapshot.activeInvocationCount == 0)
}

@Test func GEN002_unstubbedSharedWitnessReportsItsOriginalDeclarationFile() throws {
    let issues = StoredProperty<[MockIssue]>([])
    let mock = InheritedDirectoryMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }) { _ in }
    let writer: any InheritedDirectoryWriteBranch = mock
    writer.mark("missing")

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.endpoint.rawValue == "schema1|ConsumerDomain.InheritedDirectory|mark(_:String)->Void|Sendable")
    #expect(issue.source.fileID == "ConsumerDomain/InheritedDirectoryRoot.swift")
    #expect(issue.source.filePath == "InheritedDirectoryRoot.swift")
    #expect(issue.source.line == 8)
    #expect(issue.source.column == 1)
    #expect(mock.verify.mark(.equal("missing"), phase: .returned).wasCalled(.once).passed)
}
