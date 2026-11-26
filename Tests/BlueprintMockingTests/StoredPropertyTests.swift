import Testing
@testable import BlueprintMocking

private final class StoredValue: Sendable {
    let number: Int
    private let onRelease: @Sendable () -> Void

    init(_ number: Int, onRelease: @escaping @Sendable () -> Void = {}) {
        self.number = number
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@Test func RUN016_displacedStoredValueCanReadAndWriteItsReplacement() {
    let property = StoredProperty<StoredValue?>(nil)
    let observed = CriticalState<Int?>(nil)
    property.set(StoredValue(1) {
        let published = property.get()?.number
        observed.withLock { $0 = published }
        property.set(StoredValue(3))
    })

    property.set(StoredValue(2))

    #expect(observed.withLock { $0 } == 2)
    #expect(property.get()?.number == 3)
}

private final class ActorStoredValue {
    var number: Int
    private let onRelease: @MainActor () -> Void

    init(_ number: Int, onRelease: @escaping @MainActor () -> Void = {}) {
        self.number = number
        self.onRelease = onRelease
    }

    deinit {
        let callback = onRelease
        MainActor.assumeIsolated { callback() }
    }
}

@Test @MainActor func RUN016_mainActorStoredValueIsPublishedBeforeDisplacement() {
    let property = MainActorStoredProperty<ActorStoredValue?>(nil)
    var observed: Int?
    property.set(ActorStoredValue(1) {
        observed = property.get()?.number
        property.set(ActorStoredValue(3))
    })
    let replacement = ActorStoredValue(2)

    property.set(replacement)

    #expect(observed == 2)
    #expect(property.get()?.number == 3)
}
