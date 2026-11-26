/// An opt-in backing value for a mock property's getter and setter.
public final class StoredProperty<Value: Sendable>: Sendable {
    private let state: CriticalState<Value>

    public init(_ initialValue: Value) {
        state = CriticalState(initialValue)
    }

    public func get() -> Value { state.withLock { $0 } }

    public func set(_ value: Value) {
        let displaced = state.withLock { current in
            let previous = current
            current = value
            return previous
        }
        // A value's destructor may use this property. Keep it alive past unlocking.
        withExtendedLifetime(displaced) {}
    }
}

/// An opt-in backing value whose contents stay on the main actor.
@MainActor
public final class MainActorStoredProperty<Value> {
    private var value: Value

    public init(_ initialValue: Value) {
        value = initialValue
    }

    public func get() -> Value { value }

    public func set(_ value: Value) {
        let displaced = self.value
        self.value = value
        // Publish the replacement before any destructor can reenter the property.
        withExtendedLifetime(displaced) {}
    }
}
