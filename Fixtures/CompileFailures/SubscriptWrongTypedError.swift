import BlueprintMocking
import ConsumerDoubles

enum WrongSubscriptFailure: Error { case offline }

func invalid(_ stubs: EffectfulSubscriptDirectoryMock.Stubs) {
    stubs.get_subscript(.any, region: .any).willThrow(WrongSubscriptFailure.offline)
}
