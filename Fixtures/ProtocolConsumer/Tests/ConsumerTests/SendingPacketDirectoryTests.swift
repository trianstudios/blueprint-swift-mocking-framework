import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

private actor PacketProvider {
    func exchange(_ packet: sending SendingPacket) -> sending SendingPacket {
        packet.value += 1
        return SendingPacket(packet.value * 10)
    }
}

private actor PacketClient {
    func exchange(_ packetValue: Int, on directory: any SendingPacketDirectory) async -> Int {
        let incoming = await directory.exchange(SendingPacket(packetValue))
        incoming.value += 10
        return incoming.value
    }
}

@Test func GEN034_generatedSendingWitnessTransfersBothDirectionsAndRetainsOnlySnapshots() async throws {
    let session = MockSession()
    let provider = PacketProvider()
    let mockReference = StoredProperty<SendingPacketDirectoryMock?>(nil)
    let mock = SendingPacketDirectoryMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") },
        session: session,
        projectSendingInput: { packet in
            let check = mockReference.get()?.verify.exchange(.any).wasCalled(.never)
            #expect(check?.status == .incompleteHistory)
            #expect(check?.pendingInvocationIDs.count == 1)
            #expect(check?.captures.isEmpty == true)
            #expect(session.snapshot().activeInvocationCount == 1)
            return packet.value
        },
        projectSendingResult: { packet in
            let pending = mockReference.get()?.verify.exchange(.any).projectedHistory()
                .verify(.never, matchingResult: .any, phase: .admitted)
            #expect(pending?.status == .incompleteHistory)
            #expect(pending?.pendingInvocationIDs.count == 1)
            return packet.value
        }
    ) { stubs in
        stubs.exchange(Matcher { [2, 4].contains($0) }).willAnswer {
            @Sendable (packet: sending SendingPacket) async -> sending SendingPacket in
            let metadata = packet.value
            let check = mockReference.get()?.verify.exchange(.equal(metadata)).wasCalled(.once)
            #expect(check?.captures.map(\.value) == [metadata])
            return await provider.exchange(packet)
        }
        stubs.status().willReturn("ready")
    }
    mockReference.set(mock)
    defer { mockReference.set(nil) }

    let client = PacketClient()
    let first = await client.exchange(2, on: mock)
    let second = await client.exchange(4, on: mock)
    #expect(first == 40 && second == 60)
    let history = mock.verify.exchange(.any).projectedHistory()
    #expect(history.calls.map(\.argument) == [.value(2), .value(4)])
    #expect(history.calls.map(\.result) == [.value(30), .value(50)])
    #expect(history.calls.map(\.phase) == [.returned, .returned])
    #expect(mock.verify.exchange(.equal(2), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.exchange(.equal(9)).wasCalled(.never).passed)
    #expect(session.snapshot().events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(session.snapshot().activeInvocationCount == 0)
    #expect(mock.status() == "ready")

    _ = try session.resetHistory()
    #expect(mock.verify.exchange(.any).projectedHistory().calls.isEmpty)
}
