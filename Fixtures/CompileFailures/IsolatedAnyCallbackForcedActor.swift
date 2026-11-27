import ConsumerDomain

func forceMainActor(_ callback: @escaping @isolated(any) @Sendable (Int) -> String)
    -> @MainActor @Sendable (Int) -> String {
    callback
}
