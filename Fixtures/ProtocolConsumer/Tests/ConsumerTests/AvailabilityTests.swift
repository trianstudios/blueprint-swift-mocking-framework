import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN004B_protocolBaselineRemainsAvailableAtPackageFloor() {
    #expect(readAvailabilityBaseline(FloorAvailabilityDirectory()) == 13)
}

@Test func GEN004B_guardedMockKeepsReceiptStorageAndSurfacesAvailable() {
    guard #available(macOS 14.0, *) else { return }
    let mock = AvailabilityDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.baseline().willReturn(23)
        stubs.receipt().willReturn(NewReceipt(47))
    }

    let directory: any AvailabilityDirectory = mock
    #expect(readAvailabilityBaseline(directory) == 23)
    #expect(readAvailabilityReceipt(directory).number == 47)
    #expect(mock.verify.baseline(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.receipt(phase: .returned).wasCalled(.once).passed)
    print("BLUEPRINT_AVAILABILITY_GUARDED_RECEIPT Swift.Int 47")
}
