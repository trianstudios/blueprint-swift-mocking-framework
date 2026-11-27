import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@MainActor
private final class FreshOwnedResultProbe {
    var factoryInputs: [Int] = []
    var destroyed: [Int] = []
}

private func discard(_ value: consuming FreshOwnedTicket) {}

@Test @MainActor func GEN033_generatedFactoryYieldsIndependentlyOwnedResults() throws {
    let session = MockSession()
    let probe = FreshOwnedResultProbe()
    let mock = FreshOwnedTicketSourceMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session
    ) { stubs in
        stubs.issue(.equal(7)).willProduce { key in
            #expect(session.snapshot().activeInvocationCount == 1)
            let number = MainActor.assumeIsolated {
                probe.factoryInputs.append(key)
                return key * 100 + probe.factoryInputs.count
            }
            return FreshOwnedTicket(number: number) { id in
                MainActor.assumeIsolated { probe.destroyed.append(id) }
            }
        }
        stubs.complimentary().willProduce { _ in
            FreshOwnedTicket(number: 200) { id in
                MainActor.assumeIsolated { probe.destroyed.append(id) }
            }
        }
        stubs.status().willReturn("ordinary")
    }
    let source: any FreshOwnedTicketSource = mock
    #expect(probe.factoryInputs.isEmpty && probe.destroyed.isEmpty)
    let first = source.issue(7)
    let second = source.issue(7)
    let gift = source.complimentary()
    let firstNumber = first.number
    let secondNumber = second.number
    let giftNumber = gift.number
    #expect([firstNumber, secondNumber, giftNumber] == [701, 702, 200])
    #expect(probe.factoryInputs == [7, 7] && probe.destroyed.isEmpty)
    #expect(source.status() == "ordinary")

    let check: Verification<Int> = mock.verify.issue(.equal(7), phase: .returned)
    #expect(check.wasCalled(.exactly(2)).passed)
    #expect(mock.verify.issue(.equal(8)).wasCalled(.never).passed)
    #expect(mock.verify.complimentary(phase: .returned).wasCalled(.once).passed)
    let finished = try session.finishIfQuiescent()
    #expect(finished.events.map(\.phase) == [.admitted, .returned, .admitted, .returned,
                                           .admitted, .returned, .admitted, .returned])
    #expect(finished.events.first?.endpoint.rawValue.contains("->ConsumerDomain.FreshOwnedTicket") == true)
    #expect(finished.activeInvocationCount == 0 && probe.destroyed.isEmpty)

    discard(consume second)
    #expect(probe.destroyed == [702])
    discard(consume gift)
    #expect(probe.destroyed == [702, 200])
    discard(consume first)
    #expect(probe.destroyed == [702, 200, 701])
    #expect(check.wasCalled(.exactly(2)).passed)
    #expect(probe.factoryInputs == [7, 7])
}
