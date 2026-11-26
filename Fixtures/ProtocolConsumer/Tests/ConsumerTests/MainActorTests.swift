import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@MainActor
private final class DisplayState {
    var prefix = "Account: "
    var observed: [String] = []
}

@Test @MainActor func GEN035_generatedWitnessesAndControlsRetainMainActorIsolation() async throws {
    let state = DisplayState()
    let requested = DirectoryEntry("Ada")
    let sameName = DirectoryEntry("Ada")
    let matchRequested = MainActorMatcher<DirectoryEntry> { entry in
        MainActor.preconditionIsolated()
        return entry === requested && state.prefix == "Account: "
    }
    let mock = MainActorDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.display(matchRequested).willAnswer { entry in
            MainActor.preconditionIsolated()
            state.observed.append("display")
            return DirectoryEntry(state.prefix + entry.name)
        }
        stubs.refresh(.any).willThrow(.unavailable)
        stubs.refresh(matchRequested).willAnswer { entry async throws(DirectoryFailure) in
            MainActor.preconditionIsolated()
            await Task.yield()
            MainActor.preconditionIsolated()
            state.observed.append("refresh")
            entry.name += " (refreshed)"
            return entry
        }
    }

    #expect(mock.verify.display(.any).wasCalled(.never).passed)
    #expect(mock.verify.refresh(.any).wasCalled(.never).passed)
    let screen = DirectoryScreen(directory: mock)
    let label = screen.display(requested)
    #expect(label.name == "Account: Ada")
    let refreshed = try await screen.refresh(requested)
    #expect(refreshed === requested)
    #expect(refreshed.name == "Ada (refreshed)")
    do {
        _ = try await screen.refresh(sameName)
        Issue.record("Expected DirectoryFailure.unavailable")
    } catch {
        #expect(error == .unavailable)
    }

    #expect(state.observed == ["display", "refresh"])
    #expect(mock.verify.display(matchRequested, phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.refresh(matchRequested, phase: .returned).wasCalled(.once).passed)
    let matchSameName = MainActorMatcher<DirectoryEntry> { $0 === sameName }
    #expect(mock.verify.display(matchSameName).wasCalled(.never).passed)
    #expect(mock.verify.refresh(matchSameName, phase: .threw).wasCalled(.once).passed)
}
