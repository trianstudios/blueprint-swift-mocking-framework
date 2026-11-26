public enum EffectfulSubscriptFailure: Error {
    case unavailable
}

public protocol EffectfulSubscriptDirectory: Sendable {
    subscript(_ key: String, region region: Int) -> String { get async throws(EffectfulSubscriptFailure) }
    subscript(sync index: Int) -> Int { get throws(EffectfulSubscriptFailure) }
    subscript(asyncValue index: Int) -> Int { get async }
    subscript(infallible key: String) -> String { get throws(Never) }
}
