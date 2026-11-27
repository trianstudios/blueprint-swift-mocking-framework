import BlueprintMocking
import ConsumerDoubles

public struct NarrowCacheProvider: GenericActorCacheMockBehavior {
    public func lookup<Key: Hashable & Comparable & Sendable>(_ key: Key) async -> GenericSpyDecision<String?> {
        .forward
    }
}
