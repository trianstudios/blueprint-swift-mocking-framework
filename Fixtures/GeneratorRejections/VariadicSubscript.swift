public protocol VariadicSubscript: Sendable {
    static subscript(_ indices: Int...) -> String { get }
}
