import SpanDomain

public struct IllegalCallbackOwner: ScopedSpanDirectory {
    let enqueue: @Sendable (@escaping () -> Int) -> Void

    public func withPrefix(
        _ source: borrowing Span<UInt8>,
        read: (borrowing Span<UInt8>) -> Int
    ) -> Int {
        enqueue {
            let independent: ArraySlice<UInt8> = [2][...]
            return read(independent.span)
        }
        return 0
    }
}
