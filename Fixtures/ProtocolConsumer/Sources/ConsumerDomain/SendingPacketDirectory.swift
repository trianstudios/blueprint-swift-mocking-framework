public final class SendingPacket {
    public var value: Int

    public init(_ value: Int) { self.value = value }
}

public protocol SendingPacketDirectory: Sendable {
    func exchange(_ input: sending SendingPacket) async -> sending SendingPacket
    func status() -> String
}
