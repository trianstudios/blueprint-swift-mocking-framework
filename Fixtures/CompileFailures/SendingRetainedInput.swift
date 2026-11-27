import ConsumerDomain

actor SendingInputHistory {
    private var history: [SendingPacket] = []

    func cannotTransferRetainedInput(_ directory: any SendingPacketDirectory) async {
        let input = SendingPacket(1)
        history.append(input)
        _ = await directory.exchange(input)
    }
}
