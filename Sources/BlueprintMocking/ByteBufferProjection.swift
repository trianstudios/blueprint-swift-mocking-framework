/// An owned snapshot of a byte buffer observed during a synchronous call.
public struct ByteBufferSnapshot: Equatable, Sendable {
    /// The number of elements in the source buffer.
    public let count: Int

    /// Whether the source buffer had a base address.
    public let hasBaseAddress: Bool

    /// An owned prefix when copying was selected. Metadata-only snapshots use nil.
    public let bytes: [UInt8]?

    /// Whether an explicitly selected copy omitted source bytes.
    public var isTruncated: Bool {
        guard let bytes else { return false }
        return bytes.count < count
    }

    fileprivate init(count: Int, hasBaseAddress: Bool, bytes: [UInt8]?) {
        self.count = count
        self.hasBaseAddress = hasBaseAddress
        self.bytes = bytes
    }
}

/// A synchronous projection for explicit adapters to snapshot-accepting dependencies.
public struct ByteBufferProjection: Sendable {
    private let maximumBytes: Int?

    /// Observes the buffer's count and whether it has a base address.
    public init() {
        maximumBytes = nil
    }

    /// Copies a prefix capped by the given nonnegative limit.
    public init(copyingPrefixAtMost maximumBytes: Int) {
        precondition(maximumBytes >= 0, "The byte buffer copy limit must be nonnegative")
        self.maximumBytes = maximumBytes
    }

    /// The caller must keep the buffer and any copied bytes valid for this call.
    public func snapshot(_ buffer: UnsafeBufferPointer<UInt8>) -> ByteBufferSnapshot {
        let bytes = maximumBytes.map { Array(buffer.prefix($0)) }
        return ByteBufferSnapshot(count: buffer.count, hasBaseAddress: buffer.baseAddress != nil, bytes: bytes)
    }
}
