import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct TestByteBufferReaderAdapter: BorrowedByteBufferReader {
    let downstream: any SnapshotByteBufferReader
    var projection = ByteBufferProjection()

    func read(_ buffer: UnsafeBufferPointer<UInt8>) -> Int {
        let snapshot = projection.snapshot(buffer)
        return downstream.read(ByteReadSnapshot(count: snapshot.count, hasBaseAddress: snapshot.hasBaseAddress,
                                                bytes: snapshot.bytes, isTruncated: snapshot.isTruncated))
    }
}

private func forwardAndOverwrite(_ reader: any BorrowedByteBufferReader, count: Int) -> Int {
    var input = (0..<count).map { UInt8($0 + 10) }
    let outcome = input.withUnsafeMutableBufferPointer { mutable in
        let result = reader.read(UnsafeBufferPointer(mutable))
        for index in mutable.indices { mutable[index] = 255 }
        return result
    }
    #expect(input.allSatisfy { $0 == 255 })
    return outcome
}

@Test func GEN040_explicitByteBufferAdapterCopiesOnlyTheBoundedPrefix() {
    let session = MockSession()
    let mock = SnapshotByteBufferReaderMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session
    ) { stubs in
        stubs.read(.any).willAnswer { $0.bytes?.count ?? -1 }
    }
    let copy = TestByteBufferReaderAdapter(downstream: mock, projection: .init(copyingPrefixAtMost: 2))
    let zero = TestByteBufferReaderAdapter(downstream: mock, projection: .init(copyingPrefixAtMost: 0))
    let metadata = TestByteBufferReaderAdapter(downstream: mock)
    let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)

    #expect(forwardAndOverwrite(copy, count: 4) == 2)
    #expect(forwardAndOverwrite(copy, count: 2) == 2)
    #expect(forwardAndOverwrite(copy, count: 1) == 1)
    #expect(forwardAndOverwrite(zero, count: 3) == 0)
    #expect(forwardAndOverwrite(metadata, count: 4) == -1)
    #expect(copy.read(empty) == 0)
    #expect(metadata.read(empty) == -1)
    var sentinel: UInt8 = 0
    let metadataWithBase = withUnsafePointer(to: &sentinel) {
        metadata.read(UnsafeBufferPointer(start: $0, count: 0))
    }
    #expect(metadataWithBase == -1)

    // All nonempty source buffers have already been overwritten and released.
    let expected = [
        ByteReadSnapshot(count: 4, hasBaseAddress: true, bytes: [10, 11], isTruncated: true),
        ByteReadSnapshot(count: 2, hasBaseAddress: true, bytes: [10, 11], isTruncated: false),
        ByteReadSnapshot(count: 1, hasBaseAddress: true, bytes: [10], isTruncated: false),
        ByteReadSnapshot(count: 3, hasBaseAddress: true, bytes: [], isTruncated: true),
        ByteReadSnapshot(count: 4, hasBaseAddress: true, bytes: nil, isTruncated: false),
        ByteReadSnapshot(count: 0, hasBaseAddress: false, bytes: [], isTruncated: false),
        ByteReadSnapshot(count: 0, hasBaseAddress: false, bytes: nil, isTruncated: false),
        ByteReadSnapshot(count: 0, hasBaseAddress: true, bytes: nil, isTruncated: false),
    ]
    for snapshot in expected {
        #expect(mock.verify.read(.equal(snapshot), phase: .returned).wasCalled(.once).passed)
    }
    #expect(mock.verify.read(.any, phase: .returned).wasCalled(.exactly(8)).passed)
    #expect(session.snapshot().events.count == 16)
    #expect(session.snapshot().activeInvocationCount == 0)
}
