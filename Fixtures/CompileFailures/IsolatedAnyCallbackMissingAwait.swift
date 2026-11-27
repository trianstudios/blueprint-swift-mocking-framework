import ConsumerDomain

nonisolated func missingActorHop(
    _ callback: @escaping @isolated(any) @Sendable (Int) -> String
) -> String {
    callback(5)
}
