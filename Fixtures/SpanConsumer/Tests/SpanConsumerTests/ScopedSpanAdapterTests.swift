import BlueprintMocking
import SpanDomain
import SpanDoubles
import Testing

private final class SpanOwner {
    let bytes: ArraySlice<UInt8> = [10, 11, 12, 13][...]
}

@MainActor
private final class ScopedSpanObservation {
    weak var owner: SpanOwner?
    var callbackBytes: [UInt8] = []
}

@MainActor
private func readBorrowedPrefix(
    through directory: any ScopedSpanDirectory, observing observation: ScopedSpanObservation
) -> Int {
    let owner = SpanOwner()
    observation.owner = owner
    let bytes = owner.bytes
    return directory.withPrefix(bytes.span) { (view: borrowing Span<UInt8>) in
        observation.callbackBytes = (0..<view.count).map { view[$0] }
        return observation.callbackBytes.reduce(0) { $0 + Int($1) }
    }
}

struct ScopedSpanEvidence: Equatable {
    let returned: Int
    let callbackBytes: [UInt8]
    let ownerReleased: Bool
    let verified: Bool
    let recordedMetadata: [[UInt8]]
    let phases: [CallPhase]
}

@MainActor
func exerciseScopedSpanAdapter() -> ScopedSpanEvidence {
    let observation = ScopedSpanObservation()
    let session = MockSession()
    let selection = SpanDirectoryMock(
        failureReporter: FailureReporter { fatalError($0.message) }, session: session,
        projectingSpan: { (view: borrowing Span<UInt8>) in
            view.count == 0 ? [] : [view[0]]
        }
    ) { stubs in
        stubs.read(.equal([10])).willReturn(2)
    }
    let directory: any ScopedSpanDirectory = ScopedSpanAdapter(prefixLength: selection)
    let returned = readBorrowedPrefix(through: directory, observing: observation)
    let verification = selection.verify.read(.equal([10]), phase: .returned).wasCalled(.once)
    return ScopedSpanEvidence(
        returned: returned, callbackBytes: observation.callbackBytes,
        ownerReleased: observation.owner == nil, verified: verification.passed,
        recordedMetadata: verification.captures.map(\.value), phases: session.snapshot().events.map(\.phase)
    )
}

@Test @MainActor func GEN037_scopedAdapterPassesTheBorrowedSubviewOnlyToItsNonescapingCallback() {
    let evidence = exerciseScopedSpanAdapter()
    #expect(evidence == ScopedSpanEvidence(returned: 21, callbackBytes: [10, 11], ownerReleased: true,
                                          verified: true, recordedMetadata: [[10]], phases: [.admitted, .returned]))
}
