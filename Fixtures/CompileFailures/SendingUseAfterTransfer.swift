import ConsumerDomain

func cannotReuseAlias(_ directory: any SendingPacketDirectory) async -> Int {
    let packet = SendingPacket(1)
    let alias = packet
    _ = await directory.exchange(packet)
    return alias.value
}
