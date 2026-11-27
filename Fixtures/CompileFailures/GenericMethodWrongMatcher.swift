import BlueprintMocking
import ConsumerDoubles

func invalidGenericMethodMatcher(_ stubs: GenericMethodDirectoryMock.Stubs) {
    let _: SyncStub<Int, Int> = stubs.transform(Matcher<String>.any, as: Int.self)
}
