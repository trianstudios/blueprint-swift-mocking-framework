import SpanDomain

public func escapeScopedSpanView(
    _ directory: any ScopedSpanDirectory,
    input: borrowing Span<UInt8>,
    enqueue: (@escaping () -> Int) -> Void
) {
    _ = directory.withPrefix(input) { (view: borrowing Span<UInt8>) in
        enqueue { view.count }
        return 0
    }
}
