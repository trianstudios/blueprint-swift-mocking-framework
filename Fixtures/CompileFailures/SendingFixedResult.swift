import ConsumerDomain
import ConsumerDoubles

func cannotReplayFixedPacket(_ stubs: SendingPacketDirectoryMock.Stubs, packet: SendingPacket) {
    stubs.exchange(.any).willAnswer { _ in packet }
}
