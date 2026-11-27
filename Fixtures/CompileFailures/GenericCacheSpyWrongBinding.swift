import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

private actor IntegerCache: GenericActorCache {
    typealias Value = Int
    func lookup<Key: Hashable & Sendable>(_ key: Key) async -> Int? { nil }
}

public func useWrongCacheValue() -> GenericActorCacheMock {
    GenericActorCacheMock(failureReporter: FailureReporter { _ in }, forwardingTo: IntegerCache())
}
