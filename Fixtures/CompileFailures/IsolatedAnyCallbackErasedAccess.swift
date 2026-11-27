import ConsumerDomain

nonisolated func cannotUseActorState(
    _ callback: @escaping @isolated(any) @Sendable (Int) -> String
) -> Int? {
    let isolatedOwner: (any Actor)? = callback.isolation
    guard let counter = isolatedOwner as? IsolatedAnyCallbackWorker else { return nil }
    return counter.instanceValue
}
