import Foundation
#if canImport(Synchronization)
import Synchronization
#endif

/// Synchronous, non-reentrant storage for Blueprint-owned state transitions.
/// Keep user callbacks and disposal of removed values outside withLock.
final class CriticalState<State: Sendable>: Sendable {
    private let storage: any CriticalStateStorage<State>

    init(_ initialState: State, forceFoundation: Bool = false) {
        #if canImport(Synchronization)
        if !forceFoundation,
           #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            storage = MutexStorage(initialState)
            return
        }
        #endif
        storage = NSLockStorage(initialState)
    }

    var usesMutex: Bool { storage.usesMutex }

    func withLock<Result: Sendable, Failure: Error>(
        _ update: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try storage.withLock(update)
    }
}

private protocol CriticalStateStorage<State>: Sendable {
    associatedtype State: Sendable

    var usesMutex: Bool { get }

    func withLock<Result: Sendable, Failure: Error>(
        _ update: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result
}

#if canImport(Synchronization)
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class MutexStorage<State: Sendable>: CriticalStateStorage {
    private let mutex: Mutex<State>

    init(_ initialState: State) {
        mutex = Mutex(initialState)
    }

    var usesMutex: Bool { true }

    func withLock<Result: Sendable, Failure: Error>(
        _ update: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try mutex.withLock { (state: inout sending State) throws(Failure) in
            try update(&state)
        }
    }
}
#endif

// NSLock protects every access to state, including access that throws. The inout
// reference cannot escape withLock. This is the sole unchecked backend boundary.
private final class NSLockStorage<State: Sendable>: CriticalStateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    var usesMutex: Bool { false }

    func withLock<Result: Sendable, Failure: Error>(
        _ update: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try update(&state)
    }
}
