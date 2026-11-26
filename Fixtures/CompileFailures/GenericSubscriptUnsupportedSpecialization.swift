import BlueprintMocking
import ConsumerDoubles

func invalidGenericSpecialization(_ stubs: GenericSubscriptDirectoryMock.Stubs) {
    stubs.get_subscript(Matcher<Bool>.equal(true), as: Bool.self).willReturn(false)
}
