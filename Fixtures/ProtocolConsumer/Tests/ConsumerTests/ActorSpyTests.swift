#if canImport(Darwin) && canImport(Dispatch)
import Dispatch
#endif
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@MainActor
private final class RealActorSpyDirectory: ActorSpyDirectory {
    private(set) var effects: [String] = []
    var nestedDisplay: (@MainActor (ActorSpyEntry) -> ActorSpyEntry)?

    func display(_ entry: ActorSpyEntry) -> ActorSpyEntry {
        MainActor.preconditionIsolated()
        #if canImport(Darwin) && canImport(Dispatch)
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        effects.append("display")
        if let nestedDisplay { return nestedDisplay(entry) }
        audit(entry)
        entry.name += "-displayed"
        return entry
    }

    func refresh(_ entry: ActorSpyEntry) async throws(ActorSpyFailure) -> ActorSpyEntry {
        MainActor.preconditionIsolated()
        await Task.yield()
        MainActor.preconditionIsolated()
        #if canImport(Darwin) && canImport(Dispatch)
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        effects.append("refresh")
        guard entry.name != "offline" else { throw .unavailable }
        entry.name += "-refreshed"
        return entry
    }

    func audit(_ entry: ActorSpyEntry) {
        MainActor.preconditionIsolated()
        effects.append("audit")
    }
}

@Test @MainActor func RUN018_mainActorSpyForwardsRealIdentityAndEffectsWithStubPrecedence() async throws {
    let real = RealActorSpyDirectory()
    let overridden = ActorSpyEntry("override")
    let replacement = ActorSpyEntry("stub")
    let mock = ActorSpyDirectoryMock(failureReporter: .swiftTesting, forwardingTo: real) { stubs in
        stubs.display(.identical(to: overridden)).willReturn(replacement)
    }
    let screen = ActorSpyScreen(directory: mock)

    #expect(screen.display(overridden) === replacement)
    #expect(overridden.name == "override")
    #expect(real.effects.isEmpty)

    let entry = ActorSpyEntry("Ada")
    #expect(screen.display(entry) === entry)
    #expect(entry.name == "Ada-displayed")
    let refreshed = try await screen.refresh(entry)
    #expect(refreshed === entry)
    #expect(refreshed.name == "Ada-displayed-refreshed")

    let offline = ActorSpyEntry("offline")
    do {
        _ = try await screen.refresh(offline)
        Issue.record("Expected ActorSpyFailure.unavailable from the real directory")
    } catch {
        #expect(error == .unavailable)
    }
    #expect(real.effects == ["display", "audit", "refresh", "refresh"])

    #expect(mock.verify.display(.identical(to: overridden), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.display(.identical(to: overridden), phase: .returned,
                                origin: .forwarded).wasCalled(.never).passed)
    #expect(mock.verify.display(.identical(to: entry), phase: .returned,
                                origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.refresh(.identical(to: entry), phase: .returned,
                                origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.refresh(.identical(to: offline), phase: .threw,
                                origin: .forwarded).wasCalled(.once).passed)
    #expect(mock.verify.audit(.any).wasCalled(.never).passed)
}

@Test @MainActor func RUN018_realMainActorProviderCanReenterTheSpyWithADifferentInput() {
    let real = RealActorSpyDirectory()
    let outer = ActorSpyEntry("outer")
    let inner = ActorSpyEntry("inner")
    let spy = ActorSpyDirectoryMock(failureReporter: .swiftTesting, forwardingTo: real) { stubs in
        stubs.display(.identical(to: inner)).willReturn(inner)
    }
    real.nestedDisplay = { [weak spy] _ in
        guard let spy else { preconditionFailure("Expected the owning spy to stay alive") }
        return spy.display(inner)
    }

    #expect(spy.display(outer) === inner)
    #expect(real.effects == ["display"])
    #expect(spy.verify.display(.any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(spy.verify.display(.identical(to: outer), phase: .returned, origin: .forwarded).wasCalled(.once).passed)
    #expect(spy.verify.display(.identical(to: inner), phase: .returned, origin: .forwarded).wasCalled(.never).passed)
}
