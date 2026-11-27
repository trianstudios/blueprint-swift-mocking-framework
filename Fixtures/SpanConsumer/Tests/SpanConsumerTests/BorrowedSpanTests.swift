import BlueprintMocking
import SpanDomain
import SpanDoubles
import Testing

@MainActor
private final class SpanProjectionProbe {
    weak var mock: SpanDirectoryMock?
    var projections = 0
}

private func readAndRelease(_ reader: any SpanDirectory) -> Int {
    let owner: ArraySlice<UInt8> = (10..<14).map { UInt8($0) }[...]
    return reader.read(owner.span)
}

@Test @MainActor func GEN037_borrowedSpanProjectsOwnedBytesBeforeItsOwnerReleases() {
    let session = MockSession()
    let probe = SpanProjectionProbe()
    let mock = SpanDirectoryMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session,
        projectingSpan: { (source: borrowing Span<UInt8>) in
            let pending = MainActor.assumeIsolated {
                probe.projections += 1
                return probe.mock?.verify.read(.any).wasCalled(.never)
            }
            #expect(pending?.status == .incompleteHistory)
            #expect(pending?.pendingInvocationIDs.count == 1)
            #expect(pending?.captures.isEmpty == true)
            #expect(session.snapshot().activeInvocationCount == 1)
            let count = min(source.count, 2)
            var owned: [UInt8] = []
            for index in 0..<count { owned.append(source[index]) }
            return owned
        }
    ) { stubs in
        stubs.read(.equal([10, 11])).willAnswer { $0.count }
        stubs.status().willReturn("ordinary")
    }
    probe.mock = mock
    defer { probe.mock = nil }
    #expect(probe.projections == 0)
    #expect(mock.verify.read(.any).wasCalled(.never).passed)
    let reader: any SpanDirectory = mock
    #expect(readAndRelease(reader) == 2)
    let result = mock.verify.read(.equal([10, 11]), phase: .returned).wasCalled(.once)
    #expect(result.passed)
    #expect(result.captures.map(\.value) == [[10, 11]])
    #expect(reader.status() == "ordinary")
    #expect(probe.projections == 1)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(session.snapshot().activeInvocationCount == 0)
}
