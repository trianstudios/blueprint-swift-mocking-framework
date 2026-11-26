import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: EffectDirectoryMock.Stubs) {
    stubs.cachedName(id: .any).willAnswer { id async throws in id }
}
