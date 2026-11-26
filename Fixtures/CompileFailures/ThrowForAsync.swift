import BlueprintMocking
import ConsumerDoubles

enum StubError: Error { case unexpected }

func invalid(_ stubs: EffectDirectoryMock.Stubs) {
    stubs.refreshedName(id: .any).willThrow(StubError.unexpected)
}
