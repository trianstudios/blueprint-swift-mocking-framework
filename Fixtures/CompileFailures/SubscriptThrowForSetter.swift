import BlueprintMocking
import ConsumerDoubles

enum SetterFailure: Error { case offline }

func invalid(_ stubs: SubscriptDirectoryMock.Stubs) {
    stubs.set_subscript(.any, column: .any, newValue: .any).willThrow(SetterFailure.offline)
}
