import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

public func captureDeferredBuffer(_ buffer: UnsafeBufferPointer<UInt8>) -> SnapshotByteBufferReaderMock {
    SnapshotByteBufferReaderMock(failureReporter: FailureReporter { _ in }) { stubs in
        stubs.read(.any).willAnswer { _ in Int(buffer.first ?? 0) }
    }
}
