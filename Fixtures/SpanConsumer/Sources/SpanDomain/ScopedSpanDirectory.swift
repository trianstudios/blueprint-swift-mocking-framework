/// Synchronous seam for clients that use a selected view while its caller still owns the bytes.
public protocol ScopedSpanDirectory: Sendable {
    func withPrefix(_ source: borrowing Span<UInt8>, read: (borrowing Span<UInt8>) -> Int) -> Int
}

public struct ScopedSpanAdapter: ScopedSpanDirectory {
    private let prefixLength: any SpanDirectory

    public init(prefixLength: any SpanDirectory) {
        self.prefixLength = prefixLength
    }

    public func withPrefix(
        _ source: borrowing Span<UInt8>,
        read: (borrowing Span<UInt8>) -> Int
    ) -> Int {
        let count = prefixLength.read(source)
        return read(source.extracting(first: count))
    }
}
