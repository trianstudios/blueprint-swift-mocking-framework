import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

func invalid() {
    _ = UserRepositoryMock(failureReporter: FailureReporter { _ in },
                           failureMapping0: { _ in RepositoryError.offline }) { _ in }
}
