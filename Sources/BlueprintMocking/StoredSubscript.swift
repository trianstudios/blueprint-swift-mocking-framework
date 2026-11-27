/// An opt-in backing store for the getters and setters of a checked Sendable subscript.
public final class StoredSubscript<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private typealias EntryID = UInt64

    // Key lookup and index edits happen on snapshots. The gate only touches entry IDs.
    private struct State: Sendable {
        var index: [Key: EntryID] = [:]
        var values: [EntryID: Value] = [:]
        var version: UInt64 = 0
        var nextEntryID: EntryID = 0
    }

    private let state = CriticalState(State())

    public init() {}

    public func get(_ key: Key) -> Value? {
        while true {
            let (index, version) = state.withLock { ($0.index, $0.version) }
            let entryID = index[key]
            let read = state.withLock { current -> (valid: Bool, value: Value?) in
                guard current.version == version else { return (false, nil) }
                return (true, entryID.flatMap { current.values[$0] })
            }
            withExtendedLifetime(index) {}
            if read.valid { return read.value }
        }
    }

    public func set(_ value: Value, for key: Key) {
        while true {
            let (index, version, nextEntryID) = state.withLock { ($0.index, $0.version, $0.nextEntryID) }
            let existing = index[key]
            let entryID = existing ?? nextEntryID
            var replacementIndex = index
            if existing == nil { replacementIndex[key] = entryID }

            let write = state.withLock { current -> (committed: Bool, retired: Value?) in
                guard current.version == version else { return (false, nil) }
                if existing == nil {
                    current.index = replacementIndex
                    current.nextEntryID += 1
                    current.version += 1
                }
                return (true, current.values.updateValue(value, forKey: entryID))
            }
            // ARC can run user code for an old key or value.
            withExtendedLifetime((index, replacementIndex, write.retired)) {}
            if write.committed { return }
        }
    }

    @discardableResult
    public func removeValue(for key: Key) -> Value? {
        while true {
            let (index, version) = state.withLock { ($0.index, $0.version) }
            var replacementIndex = index
            let entryID = replacementIndex.removeValue(forKey: key)

            let removal = state.withLock { current -> (committed: Bool, value: Value?) in
                guard current.version == version else { return (false, nil) }
                guard let entryID else { return (true, nil) }
                current.index = replacementIndex
                current.version += 1
                return (true, current.values.removeValue(forKey: entryID))
            }
            // The removed key remains alive until the committed index is visible.
            withExtendedLifetime((index, replacementIndex)) {}
            if removal.committed { return removal.value }
        }
    }
}
