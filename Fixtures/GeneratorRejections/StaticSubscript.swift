public protocol StaticSubscript: Sendable {
    static subscript(_ index: Int) -> String { get }
}
