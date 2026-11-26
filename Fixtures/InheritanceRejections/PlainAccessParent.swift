public protocol PlainAccessParent: Sendable {
    func flush(_ label: String) -> String
}
