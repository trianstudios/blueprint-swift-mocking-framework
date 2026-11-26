import BlueprintMocking
import ConsumerDoubles

func invalidGenericMatcher(_ stubs: GenericSubscriptDirectoryMock.Stubs) {
    stubs.get_subscript(Matcher<String>.equal("wrong"), as: Int.self).willReturn(1)
}
