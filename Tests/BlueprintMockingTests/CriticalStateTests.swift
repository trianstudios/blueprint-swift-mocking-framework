import Testing
@testable import BlueprintMocking

private var automaticUsesMutex: Bool {
    #if canImport(Synchronization)
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) { return true }
    #endif
    return false
}

private enum CriticalStateTestFailure: Error { case expected }

private final class RetirementProbe: Sendable {
    let didRetire: @Sendable () -> Void

    init(didRetire: @escaping @Sendable () -> Void) {
        self.didRetire = didRetire
    }

    deinit { didRetire() }
}

@Test(arguments: [false, true])
func RUN042_criticalStateSerializesContendedUpdates(forceFoundation: Bool) async {
    let state = CriticalState(0, forceFoundation: forceFoundation)
    #expect(state.usesMutex == (!forceFoundation && automaticUsesMutex))

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1_000 {
                    state.withLock { $0 += 1 }
                }
            }
        }
    }

    #expect(state.withLock { $0 } == 8_000)
}

@Test(arguments: [false, true])
func RUN042_criticalStateUnlocksAfterThrow(forceFoundation: Bool) {
    let state = CriticalState(0, forceFoundation: forceFoundation)
    do {
        try state.withLock { (value: inout Int) throws(CriticalStateTestFailure) in
            value += 1
            throw .expected
        }
        Issue.record("Expected typed failure")
    } catch {
        #expect(error == .expected)
    }

    #expect(state.withLock { $0 } == 1)
}

@Test(arguments: [false, true])
func RUN042_retiredValueCanReenterCriticalStateAfterUnlock(forceFoundation: Bool) {
    let state = CriticalState<RetirementProbe?>(nil, forceFoundation: forceFoundation)
    let didReenter = CriticalState(false, forceFoundation: forceFoundation)
    state.withLock { value in
        value = RetirementProbe {
            let isEmpty = state.withLock { $0 == nil }
            didReenter.withLock { $0 = isEmpty }
        }
    }

    // Return the retired value so its last release happens after unlocking.
    var retired = state.withLock { value in
        let prior = value
        value = nil
        return prior
    }
    #expect(retired != nil)
    retired = nil
    #expect(didReenter.withLock { $0 })
}
