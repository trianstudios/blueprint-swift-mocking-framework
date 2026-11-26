import BlueprintMocking
import ConsumerDoubles

enum StubError: Error { case unexpected }

func invalid(_ stubs: EffectDirectoryMock.Stubs) {
    stubs.refreshedName(id: .any).willAnswer { _ in throw StubError.unexpected }
}
