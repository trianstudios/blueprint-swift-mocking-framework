public struct Element: Swift.Sendable {}

public protocol NominalElementBranch: Swift.Sendable {
    func legacy() -> Element
}
