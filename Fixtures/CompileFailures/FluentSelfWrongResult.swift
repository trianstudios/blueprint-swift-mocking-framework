import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

private struct OtherDirectory: FluentDirectory {
    func next(id: String) -> Self { self }
}

func cannotReturnAnotherConformer(_ stubs: FluentDirectoryMock.Stubs) {
    stubs.next(id: .any).willReturn(OtherDirectory())
}
