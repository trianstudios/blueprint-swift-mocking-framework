public protocol EffectfulSubscriptSetter: Sendable {
    subscript(_ index: Int) -> String { get async set }
}
