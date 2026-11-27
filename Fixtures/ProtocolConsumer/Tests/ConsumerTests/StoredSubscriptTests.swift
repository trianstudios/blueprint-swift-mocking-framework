import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Dispatch
import Testing

@Test(.timeLimit(.minutes(1)))
func RUN016_generatedSubscriptStorageKeepsConcurrentKeysAndAccessorHistories() async {
    let storage = StoredSubscript<Int, Int>()
    let session = MockSession()
    let mock = WritableSpyDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(slot: .any).willAnswer { storage.get($0) ?? -1 }
        stubs.set_subscript(slot: .any, newValue: .any).willAnswer { arguments in
            storage.set(arguments.1, for: arguments.0)
        }
    }
    let directory: any WritableSpyDirectory = mock
    let client = WritableSpyClient(directory: directory)
    let slots = 1...32

    await withTaskGroup(of: Void.self) { tasks in
        for slot in slots {
            tasks.addTask {
                client.setScore(slot * 10, in: slot)
            }
        }
    }

    let getters = mock.verify.get_subscript(slot: .any, phase: .returned)
    let setters = mock.verify.set_subscript(slot: .any, newValue: .any,
                                          phase: .returned)
    #expect(setters.wasCalled(.exactly(slots.count)).passed)
    #expect(getters.wasCalled(.never).passed)

    for slot in slots {
        #expect(directory[slot: slot] == slot * 10)
        #expect(mock.verify.get_subscript(slot: .equal(slot), phase: .returned).wasCalled(.once).passed)
        #expect(
            mock.verify.set_subscript(slot: .equal(slot), newValue: .equal(slot * 10),
                                      phase: .returned).wasCalled(.once).passed
        )
    }

    #expect(getters.wasCalled(.exactly(slots.count)).passed)
    #expect(setters.wasCalled(.exactly(slots.count)).passed)
    let snapshot = session.snapshot()
    #expect(snapshot.activeInvocationCount == 0)
    #expect(snapshot.events.count == slots.count * 4)
}

private struct ProbedSubscriptKey: Hashable, Sendable {
    let number: Int
    var beforeHash: (@Sendable () -> Void)? = nil
    var beforeEquality: (@Sendable () -> Void)? = nil

    func hash(into hasher: inout Hasher) {
        beforeHash?()
        hasher.combine(number)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.beforeEquality?()
        rhs.beforeEquality?()
        return lhs.number == rhs.number
    }
}

// Keep a blocked lock-regression worker out of the test's cooperative executor.
private func completeReentrantStorageOperation(_ operation: @escaping @Sendable () -> Void) async throws {
    let completed = AsyncStream<Bool>.makeStream()
    DispatchQueue.global().async {
        operation()
        completed.continuation.yield(true)
        completed.continuation.finish()
    }
    var results = completed.stream.makeAsyncIterator()
    let finished = await results.next()
    try #require(finished == true)
}

@Test(.timeLimit(.minutes(1)))
func RUN016_reentrantHashAndEqualityRetryWithoutLosingIndexedUpdates() async throws {
    let storage = StoredSubscript<ProbedSubscriptKey, String>()
    let hashPending = StoredProperty(true)
    let equalityPending = StoredProperty(true)
    let removed = StoredProperty<String?>(nil)

    storage.set("untouched", for: ProbedSubscriptKey(number: 0))
    let hashKey = ProbedSubscriptKey(number: 1, beforeHash: { [weak storage] in
        guard hashPending.get(), let storage else { return }
        hashPending.set(false)
        storage.set("nested hash write", for: ProbedSubscriptKey(number: 2))
    })
    try await completeReentrantStorageOperation {
        storage.set("outer hash write", for: hashKey)
    }
    #expect(storage.get(ProbedSubscriptKey(number: 1)) == "outer hash write")
    #expect(storage.get(ProbedSubscriptKey(number: 2)) == "nested hash write")

    let plainKey = ProbedSubscriptKey(number: 3)
    storage.set("old value", for: plainKey)
    let equalKey = ProbedSubscriptKey(number: 3, beforeEquality: { [weak storage] in
        guard equalityPending.get(), let storage else { return }
        equalityPending.set(false)
        // Change the entry for this logical key while the outer lookup is comparing its old snapshot.
        removed.set(storage.removeValue(for: plainKey))
        storage.set("nested reinsertion", for: plainKey)
        storage.set("nested equality write", for: ProbedSubscriptKey(number: 4))
    })

    try await completeReentrantStorageOperation {
        storage.set("outer equality write", for: equalKey)
    }
    #expect(removed.get() == "old value")
    #expect(storage.get(plainKey) == "outer equality write")
    #expect(storage.get(ProbedSubscriptKey(number: 4)) == "nested equality write")
    #expect(storage.get(ProbedSubscriptKey(number: 0)) == "untouched")
    #expect(storage.get(ProbedSubscriptKey(number: 2)) == "nested hash write")
}

private final class KeyedRetirementPayload: Sendable {
    let number: Int
    private let onRelease: @Sendable () -> Void

    init(_ number: Int, onRelease: @escaping @Sendable () -> Void = {}) {
        self.number = number
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@Test(.timeLimit(.minutes(1)))
func RUN016_replacedSubscriptPayloadReentersAfterCommit() async throws {
    let storage = StoredSubscript<Int, KeyedRetirementPayload>()
    let observedReplacement = StoredProperty<Int?>(nil)
    let key = 7

    try await completeReentrantStorageOperation { [storage] in
        storage.set(KeyedRetirementPayload(10) { [weak storage] in
            observedReplacement.set(storage?.get(key)?.number)
        }, for: key)
        storage.set(KeyedRetirementPayload(20), for: key)
    }

    #expect(observedReplacement.get() == 20)
    #expect(storage.removeValue(for: key)?.number == 20)
    #expect(storage.get(key) == nil)
    #expect(storage.removeValue(for: key) == nil)
}
