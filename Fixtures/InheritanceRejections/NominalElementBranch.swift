public struct Element: Sendable {}

public protocol NominalElementBranch: Sendable {
    func legacy() -> Element
}
