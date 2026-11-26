public protocol VariadicSubscriptDescriptorCollision: Sendable {
    subscript(field field: String, _ indices: Int...) -> String { get }
    subscript(field field: String, _ indices: [Int]) -> String { get }
}
