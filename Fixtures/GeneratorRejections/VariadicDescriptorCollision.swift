public protocol VariadicDescriptorCollision: Sendable {
    func sample(_ values: Int...) -> Int
    func sample(_ values: [Int]) -> Int
}
