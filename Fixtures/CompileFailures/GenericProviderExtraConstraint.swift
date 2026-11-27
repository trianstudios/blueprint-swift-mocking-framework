import ConsumerDoubles

struct OverconstrainedIdentityProvider: GenericProviderDirectoryMockBehavior {
    func transform<T: Hashable & Sendable & Comparable>(_ value: T) -> T {
        value
    }
}
