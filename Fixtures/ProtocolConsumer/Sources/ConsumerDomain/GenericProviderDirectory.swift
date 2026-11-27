public protocol GenericProviderDirectory: Sendable {
    func transform<T: Hashable & Sendable>(_ value: T) -> T
    func label(for value: String) -> String
}
