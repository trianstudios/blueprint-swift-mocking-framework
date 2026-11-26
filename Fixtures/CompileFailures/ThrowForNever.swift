import BlueprintMocking
import ConsumerDoubles

enum SampleError: Error { case badInput }

func invalid(_ stubs: EffectEdgesMock.Stubs) {
    stubs.readAsync(id: .any).willThrow(SampleError.badInput)
}
