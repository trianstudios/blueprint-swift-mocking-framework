import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: SubscriptDirectoryMock.Stubs) {
    stubs.get_subscript(.equal("row"), column: .equal("name")).willReturn("Ada")
}
