public protocol AsyncAccessParent: Sendable {
    func flush(_ label: String) async -> String
}
