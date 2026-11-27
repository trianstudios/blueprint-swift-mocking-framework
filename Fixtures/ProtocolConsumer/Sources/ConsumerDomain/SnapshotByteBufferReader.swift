public struct ByteReadSnapshot: Equatable, Sendable {
    public let count: Int
    public let hasBaseAddress: Bool
    public let bytes: [UInt8]?
    public let isTruncated: Bool

    public init(count: Int, hasBaseAddress: Bool, bytes: [UInt8]?, isTruncated: Bool) {
        self.count = count
        self.hasBaseAddress = hasBaseAddress
        self.bytes = bytes
        self.isTruncated = isTruncated
    }
}

public protocol SnapshotByteBufferReader: Sendable {
    func read(_ snapshot: ByteReadSnapshot) -> Int
}

public protocol BorrowedByteBufferReader: Sendable {
    func read(_ buffer: UnsafeBufferPointer<UInt8>) -> Int
}
