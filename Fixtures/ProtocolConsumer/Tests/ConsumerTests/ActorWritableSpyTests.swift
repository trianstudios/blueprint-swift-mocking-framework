import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@MainActor
private final class RealActorWritableSpyDirectory: ActorWritableSpyDirectory {
    private var currentEntry = ActorSpyEntry("initial")
    private var entries: [String: ActorSpyEntry] = [:]
    private(set) var accesses: [String] = []

    var current: ActorSpyEntry {
        get {
            MainActor.preconditionIsolated()
            accesses.append("get current")
            return currentEntry
        }
        set {
            MainActor.preconditionIsolated()
            accesses.append("set current")
            currentEntry = newValue
        }
    }

    subscript(slot key: String) -> ActorSpyEntry {
        get {
            MainActor.preconditionIsolated()
            accesses.append("get slot \(key)")
            return entries[key] ?? ActorSpyEntry("missing")
        }
        set {
            MainActor.preconditionIsolated()
            accesses.append("set slot \(key)")
            entries[key] = newValue
        }
    }
}

@Test @MainActor func RUN018_mainActorSpyForwardsNonmutatingWritableAccessors() {
    let real = RealActorWritableSpyDirectory()
    let ignored = ActorSpyEntry("ignored")
    let replacement = ActorSpyEntry("stubbed value")
    let spy = ActorWritableSpyDirectoryMock(failureReporter: .swiftTesting, forwardingTo: real) { stubs in
        stubs.set_current(.identical(to: ignored)).willReturn(())
        stubs.get_subscript(slot: .equal("hidden")).willReturn(replacement)
        stubs.set_subscript(slot: .equal("hidden"), newValue: .identical(to: ignored)).willReturn(())
    }
    let directory: any ActorWritableSpyDirectory = spy

    directory.current = ignored
    directory[slot: "hidden"] = ignored
    #expect(directory[slot: "hidden"] === replacement)
    #expect(real.accesses.isEmpty)

    let propertyValue = ActorSpyEntry("property")
    let slotValue = ActorSpyEntry("subscript")
    directory.current = propertyValue
    directory[slot: "visible"] = slotValue
    #expect(directory.current === propertyValue)
    #expect(directory[slot: "visible"] === slotValue)
    #expect(real.accesses == ["set current", "set slot visible", "get current", "get slot visible"])

    #expect(spy.verify.set_current(.identical(to: ignored), phase: .returned).wasCalled(.once).passed)
    #expect(spy.verify.set_current(.identical(to: ignored), origin: .forwarded).wasCalled(.never).passed)
    #expect(spy.verify.set_current(.identical(to: propertyValue), phase: .returned,
                                  origin: .forwarded).wasCalled(.once).passed)
    #expect(spy.verify.get_current(phase: .returned, origin: .forwarded).wasCalled(.once).passed)

    #expect(spy.verify.get_subscript(slot: .equal("hidden"), phase: .returned).wasCalled(.once).passed)
    #expect(spy.verify.get_subscript(slot: .equal("hidden"), origin: .forwarded).wasCalled(.never).passed)
    #expect(spy.verify.set_subscript(slot: .equal("hidden"), newValue: .identical(to: ignored),
                                    phase: .returned).wasCalled(.once).passed)
    #expect(spy.verify.set_subscript(slot: .equal("hidden"), newValue: .identical(to: ignored),
                                    origin: .forwarded).wasCalled(.never).passed)
    #expect(spy.verify.get_subscript(slot: .equal("visible"), phase: .returned,
                                    origin: .forwarded).wasCalled(.once).passed)
    #expect(spy.verify.set_subscript(slot: .equal("visible"), newValue: .identical(to: slotValue),
                                    phase: .returned, origin: .forwarded).wasCalled(.once).passed)
}
