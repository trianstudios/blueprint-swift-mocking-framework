import BlueprintMocking
import ConsumerDoubles

func invalidInitialization() {
    _ = AvailabilityDirectoryMock(failureReporter: FailureReporter { _ in }) { _ in }
}

func invalidEscape(_ create: () -> AvailabilityDirectoryMock) -> Any {
    create()
}
