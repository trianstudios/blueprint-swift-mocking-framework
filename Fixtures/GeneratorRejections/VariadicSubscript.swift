public protocol VariadicSubscript: Sendable {
    subscript(_ indices: Int...) -> String { get }
}
