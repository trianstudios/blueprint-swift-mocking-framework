public protocol EffectfulSetter: Sendable {
    var value: String { get async set }
}
