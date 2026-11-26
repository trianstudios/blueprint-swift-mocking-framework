/// A forwarding task inherits a handle, but only live provider calls contribute to its depth.
enum AsyncForwardingDepth {
    @TaskLocal private static var current: Lease?

    enum Decision<Output: Sendable>: Sendable {
        case completed(Output)
        case exceeded(Int)
    }

    static func run<Output: Sendable>(
        maximumDepth: Int?, _ operation: @Sendable () async -> Output
    ) async -> Decision<Output> {
        let parent = current
        if parent == nil && maximumDepth == nil {
            return .completed(await operation())
        }

        let ancestry = parent?.ancestry ?? Ancestry()
        switch ancestry.enter(parent: parent?.id, maximumDepth: maximumDepth) {
        case .untracked:
            return .completed(await operation())
        case .exceeded(let limit):
            return .exceeded(limit)
        case .tracked(let lease):
            let result = await $current.withValue(lease) {
                defer { ancestry.leave(lease.id) }
                return await operation()
            }
            return .completed(result)
        }
    }

    private struct Lease: Sendable {
        let ancestry: Ancestry
        let id: UInt64
    }

    private enum Entry: Sendable {
        case untracked
        case tracked(Lease)
        case exceeded(Int)
    }

    private final class Ancestry: Sendable {
        private struct Frame: Sendable {
            let parent: UInt64?
            let maximumDepth: Int?
        }

        private struct State: Sendable {
            var nextID: UInt64 = 0
            var active: [UInt64: Frame] = [:]
        }

        private let state = CriticalState(State())

        func enter(parent: UInt64?, maximumDepth: Int?) -> Entry {
            state.withLock { state in
                let liveParent = parent.flatMap { state.active[$0] == nil ? nil : $0 }
                var cursor = liveParent
                var limit = maximumDepth
                var depth = 0
                // An expired frame severs ancestry, including for a child that has already entered.
                while let id = cursor, let frame = state.active[id] {
                    depth += 1
                    if let ancestorLimit = frame.maximumDepth {
                        limit = min(limit ?? ancestorLimit, ancestorLimit)
                    }
                    cursor = frame.parent
                }
                guard let limit else { return .untracked }
                guard depth < limit else { return .exceeded(limit) }

                state.nextID += 1
                let id = state.nextID
                state.active[id] = Frame(parent: liveParent, maximumDepth: maximumDepth)
                return .tracked(Lease(ancestry: self, id: id))
            }
        }

        func leave(_ id: UInt64) {
            _ = state.withLock { $0.active.removeValue(forKey: id) }
        }
    }
}
