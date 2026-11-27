import BlueprintMocking
import ConsumerDoubles

func cannotStubIntOverloadWithString(_ stubs: ResultOverloadDirectoryMock.Stubs) {
    let count: SyncStub<String, Int> = stubs.lookup(id: .any, returning: Int.self)
    count.willReturn("wrong result")
}
