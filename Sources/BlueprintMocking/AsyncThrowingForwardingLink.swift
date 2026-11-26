/// An opaque, exactly typed reference that can be bound to a structural forwarding link.
public struct AsyncThrowingForwardingTarget<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    fileprivate let endpoint: AsyncThrowingEndpoint<Input, Output, Failure>

    init(endpoint: AsyncThrowingEndpoint<Input, Output, Failure>) {
        self.endpoint = endpoint
    }
}

/// A one-time binding to a weak async throwing forwarding target.
public final class AsyncThrowingForwardingLink<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    private struct WeakEndpoint: Sendable {
        weak var value: AsyncThrowingEndpoint<Input, Output, Failure>?
    }

    private enum Binding: Sendable {
        case unbound
        case bound(WeakEndpoint)
    }

    enum Snapshot: Sendable {
        case unbound
        case released
        case available(AsyncThrowingEndpoint<Input, Output, Failure>)
    }

    private let binding = CriticalState(Binding.unbound)

    public init() {}

    /// Binds once. The caller must keep the target endpoint or its handle alive while forwarding to it.
    @discardableResult
    public func bind(to target: AsyncThrowingForwardingTarget<Input, Output, Failure>) -> Bool {
        binding.withLock { binding in
            guard case .unbound = binding else { return false }
            binding = .bound(WeakEndpoint(value: target.endpoint))
            return true
        }
    }

    func snapshot() -> Snapshot {
        binding.withLock { binding in
            switch binding {
            case .unbound:
                .unbound
            case .bound(let target):
                if let endpoint = target.value { .available(endpoint) } else { .released }
            }
        }
    }
}
