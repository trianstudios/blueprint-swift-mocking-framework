import BlueprintMocking
import SpanDoubles

public func retainProjectionView(_ submit: @escaping @Sendable (@escaping () -> Int) -> Void) -> SpanDirectoryMock {
    SpanDirectoryMock(failureReporter: FailureReporter { _ in },
                      projectingSpan: { (view: borrowing Span<UInt8>) in
        submit { view.count }
        return []
    }) { _ in }
}
