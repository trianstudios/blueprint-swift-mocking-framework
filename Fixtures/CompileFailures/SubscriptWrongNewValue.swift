import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: SubscriptDirectoryMock.Stubs) {
    stubs.set_subscript(.equal(1), column: .equal("name"), newValue: .equal(42)).willReturn(())
}
