public enum LookupFailure: Error { case unavailable }

public protocol Lookup: Sendable {
    func name(for id: String) -> String
    func refresh(id: String) async throws(LookupFailure) -> String
    static subscript(_ slot: Int) -> Int { get set }
}
