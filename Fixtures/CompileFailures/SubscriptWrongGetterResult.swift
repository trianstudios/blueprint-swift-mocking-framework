import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: SubscriptDirectoryMock.Stubs) {
    stubs.get_subscript(.equal(1), column: .equal("name")).willReturn(42)
}
