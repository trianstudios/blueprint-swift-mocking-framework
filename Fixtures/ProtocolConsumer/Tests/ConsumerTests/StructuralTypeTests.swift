import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func RUN008_structuralTypesUseTypedMatchersThroughGeneratedWitnesses() {
    let one = LookupRecord(id: 1, namespace: "workspace")
    let two = LookupRecord(id: 2, namespace: "workspace")
    let mock = ValueDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.fetch(.isNil()).willReturn([:])
        stubs.fetch(.nonNil(.unorderedElements([.equal(2), .equal(1), .equal(1)])))
            .willReturn([1: one, 2: two])
        stubs.current().willReturn(nil)
    }
    let directory: any ValueDirectory = mock
    #expect(directory.fetch([1, 2, 1]) == [1: one, 2: two])
    #expect(directory.fetch(nil).isEmpty)
    #expect(directory.current() == nil)
    #expect(mock.verify.fetch(.nonNil(.orderedElements([.equal(1), .equal(2), .equal(1)])))
        .wasCalled(.once).passed)
    #expect(mock.verify.fetch(.isNil()).wasCalled(.once).passed)
    #expect(mock.verify.current().wasCalled(.once).passed)
}
