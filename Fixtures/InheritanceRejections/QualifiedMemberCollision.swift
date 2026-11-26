import ParentDomain

public protocol QualifiedMemberCollision: ParentDomain.SharedDirectory, Sendable {
    func remoteLabel(for key: String) -> Int
}
