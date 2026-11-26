import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
enum UnrelatedError: Error { case wrong }
func invalid(_ stubs: UserRepositoryMock.Stubs) {
    stubs.fetchUser(id: .any).willThrow(UnrelatedError.wrong)
}
