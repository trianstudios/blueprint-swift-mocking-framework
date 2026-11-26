import BlueprintMocking
import ConsumerDoubles

func invalid(_ stubs: EffectEdgesMock.Stubs) {
    stubs.stop(id: .any).willReturn("not possible")
}
