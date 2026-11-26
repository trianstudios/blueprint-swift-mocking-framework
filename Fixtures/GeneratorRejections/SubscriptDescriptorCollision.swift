public protocol SubscriptDescriptorCollision: Sendable {
    subscript(index: Int) -> String { get }
    func get_subscript(_ index: Int) -> String
}
