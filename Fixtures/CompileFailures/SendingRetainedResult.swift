import ConsumerDomain

actor SendingResultHistory {
    private var history: [SendingPacket] = []

    func cannotReturnRetainedResult(_ input: sending SendingPacket) -> sending SendingPacket {
        let result = SendingPacket(input.value)
        history.append(result)
        return result
    }
}
