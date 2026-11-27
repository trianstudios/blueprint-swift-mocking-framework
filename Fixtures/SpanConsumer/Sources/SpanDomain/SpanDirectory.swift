public protocol SpanDirectory: Sendable {
    func read(_ source: borrowing Swift.Span<Swift.UInt8>) -> Int
    func status() -> String
}
