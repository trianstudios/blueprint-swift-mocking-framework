public struct IntCursor: Swift.IteratorProtocol, Swift.Sendable {
    public typealias Element = Swift.Int

    private var value: Swift.Int?

    public init(_ value: Swift.Int) {
        self.value = value
    }

    public mutating func next() -> Swift.Int? {
        defer { value = nil }
        return value
    }
}
