import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import ParentDomain
import Testing

@Test func GEN008_parameterizedParentInfersConcreteWitnessAcrossTargets() throws {
    let _: Int.Type = IntDirectoryMock.Element.self
    let session = MockSession()
    let issues = StoredProperty<[MockIssue]>([])
    let mock = IntDirectoryMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }, session: session) { stubs in
        stubs.load(key: .equal("row")).willReturn(17)
        stubs.save(.equal(17)).willReturn(())
    }

    let directory: any IntDirectory = mock
    #expect(refreshIntDirectory(directory, key: "row") == 17)
    #expect(mock.verify.load(key: .equal("row"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.save(.equal(17), phase: .returned).wasCalled(.once).passed)

    let inherited: any ParentDomain.BoundParent<Int> = mock
    inherited.note(42)
    #expect(mock.verify.note(.equal(42), phase: .returned).wasCalled(.once).passed)

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    let endpoint = EndpointID("schema1|ConsumerDomain.IntDirectory|note(_:Swift.Int)->Void|Sendable")
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.endpoint == endpoint)
    #expect(issue.source.fileID == "ParentDomain/BoundParent.swift")
    #expect(issue.source.filePath == "BoundParent.swift")
    #expect(issue.source.line == 5)
    #expect(issue.source.column == 1)
    let snapshot = session.snapshot()
    let events = snapshot.events.filter { $0.endpoint == endpoint }
    #expect(events.map(\.phase) == [.admitted, .returned])
    #expect(Set(events.map(\.invocationID)).count == 1)
    #expect(snapshot.activeInvocationCount == 0)
}
