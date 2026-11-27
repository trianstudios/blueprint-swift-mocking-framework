public final class FixedDirectory: Sendable {}

public protocol FixedSelfDirectory: Sendable where Self: FixedDirectory {
    func next(id: String) -> Self
}

extension FixedDirectory: FixedSelfDirectory {
    public func next(id: String) -> FixedDirectory { self }
}
