import BlueprintMocking
import ConsumerDoubles

private struct UnrelatedDependency: Sendable {}

func invalidSpyTarget() {
    _ = SpyDirectoryMock(failureReporter: FailureReporter { _ in }, forwardingTo: UnrelatedDependency()) { _ in }
}
