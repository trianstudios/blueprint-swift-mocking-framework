/// A captured weak reference. Use separately copied values for immutable call-time state.
public struct WeakProjectedReference<Object: AnyObject & Sendable>: Sendable {
    private weak var reference: Object?

    public init(_ object: Object) {
        reference = object
    }

    /// Returns the currently live object. Holding the returned reference can keep it alive.
    /// A nil read does not change the captured projection's status.
    public var object: Object? { reference }
}
