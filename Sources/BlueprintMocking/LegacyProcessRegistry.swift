/// A registration failure in the dedicated process adapter for legacy global calls.
public enum LegacyProcessRegistryError: Error, Equatable, Sendable {
    case scopeAlreadyActive
    case noActiveScope
}

/// A typed slot for a legacy static accessor in a process dedicated to one test request.
/// Join callers that may make further lookups before replacing a registration in that process.
public final class LegacyProcessRegistry<Value: Sendable>: Sendable {
    private let state = CriticalState<Value?>(nil)

    public init() {}

    /// Makes a value available to the process for one synchronous operation.
    /// The registration is removed before this method returns or propagates an error.
    public func withScope<Result>(_ value: Value, operation: () throws -> Result) throws -> Result {
        try install(value)
        defer { clear() }
        return try operation()
    }

    /// Makes a value available to the process until the asynchronous operation returns or throws.
    /// The operation runs outside synchronization and may suspend.
    public func withScope<Result>(
        _ value: Value, isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async throws -> Result {
        try install(value)
        defer { clear() }
        return try await operation()
    }

    /// Acquires the current value synchronously, including from callers without task context.
    /// A caller that has already acquired a value may finish using it after the scope closes.
    /// New lookups after closure throw until a new registration is installed.
    public func current() throws(LegacyProcessRegistryError) -> Value {
        guard let current = state.withLock({ $0 }) else { throw .noActiveScope }
        return current
    }

    private func install(_ value: Value) throws(LegacyProcessRegistryError) {
        try state.withLock { entry throws(LegacyProcessRegistryError) in
            guard entry == nil else { throw .scopeAlreadyActive }
            entry = .some(value)
        }
    }

    private func clear() {
        let retired = state.withLock { entry in
            let value = entry
            entry = nil
            return value
        }
        withExtendedLifetime(retired) {}
    }
}
