import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: AssociatedDirectoryMock.Stubs) {
    stubs.load(key: .any).willReturn(7)
}
