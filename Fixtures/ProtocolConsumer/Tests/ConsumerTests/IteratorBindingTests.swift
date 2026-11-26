import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN008_iteratorEqualitySurvivesInheritedPrimaryNormalization() throws {
    let _: Int.Type = IntSequenceMock.Element.self
    let _: IntCursor.Type = IntSequenceMock.Iterator.self
    let issues = StoredProperty<[MockIssue]>([])
    let mock = IntSequenceMock(failureReporter: FailureReporter { issue in
        issues.set(issues.get() + [issue])
    }) { stubs in
        stubs.makeIterator().willReturn(IntCursor(17))
        stubs.first().willReturn(21)
        stubs.record(.equal(21)).willReturn(())
    }

    let sequence: any IntSequence = mock
    let fromExistential: Int? = refreshIntSequence(sequence)
    let fromGeneric: Int? = firstFromCursorSequence(mock)
    #expect(fromExistential == 17)
    #expect(fromGeneric == 17)
    var cursor = sequence.makeIterator()
    #expect(cursor.next() == 17)
    #expect(cursor.next() == nil)

    #expect(mock.verify.makeIterator(phase: .returned).wasCalled(.exactly(3)).passed)
    #expect(mock.verify.first(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.record(.equal(21), phase: .returned).wasCalled(.once).passed)
    sequence.record(99)
    #expect(mock.verify.record(.equal(99), phase: .returned).wasCalled(.once).passed)

    let recorded = issues.get()
    try #require(recorded.count == 1)
    let issue = recorded[0]
    #expect(issue.kind == .unexpectedCall)
    #expect(issue.endpoint == EndpointID("schema1|ConsumerDomain.IntSequence|record(_:Swift.Int)->Void|Sendable"))
    #expect(issue.source.fileID == "ConsumerDomain/CursorSequence.swift")
    #expect(issue.source.filePath == "CursorSequence.swift")
    #expect(issue.source.line == 7)
    #expect(issue.source.column == 1)
}
