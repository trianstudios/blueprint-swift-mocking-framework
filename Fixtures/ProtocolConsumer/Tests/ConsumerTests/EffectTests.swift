import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private enum ExampleFailure: Error, Equatable {
    case offline
}

@Test func GEN013_preservesAllFourMethodEffectsThroughARealCaller() async throws {
    let mock = EffectDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.localName(id: .equal("42")).willAnswer { "local-" + $0 }
        stubs.cachedName(id: .equal("42")).willReturn("cache")
        stubs.refreshedName(id: .equal("42")).willAnswer { id in
            await Task.yield()
            return "refresh-" + id
        }
        stubs.remoteName(id: .equal("42")).willAnswer { id in
            await Task.yield()
            return "remote-" + id
        }
    }
    #expect(mock.verify.refreshedName(id: .any).wasCalled(.never).passed)
    #expect(mock.verify.remoteName(id: .any).wasCalled(.never).passed)

    let names = try await DirectoryLoader(directory: mock).load(id: "42")
    #expect(names == ["local-42", "cache", "refresh-42", "remote-42"])
    #expect(mock.verify.localName(id: .equal("42"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.cachedName(id: .equal("42"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.refreshedName(id: .equal("42"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.remoteName(id: .equal("42"), phase: .returned).wasCalled(.once).passed)
}

@Test func GEN013_ordinaryThrowingWitnessesPreserveConfiguredErrors() async {
    let mock = EffectDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.cachedName(id: .any).willThrow(ExampleFailure.offline)
        stubs.remoteName(id: .any).willThrow(ExampleFailure.offline)
    }
    #expect(throws: ExampleFailure.offline) { try mock.cachedName(id: "42") }
    await #expect(throws: ExampleFailure.offline) { try await mock.remoteName(id: "42") }
    #expect(mock.verify.cachedName(id: .equal("42"), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.remoteName(id: .equal("42"), phase: .threw).wasCalled(.once).passed)
}

@Test func RUN039_ordinaryThrowingWitnessesReportAnIssueBeforeReturningTheirFrameworkError() async {
    let mock = EffectDirectoryMock(failureReporter: .swiftTesting) { _ in }
    // A caught missing stub is still a reported test failure. Known issue records verify this.
    withKnownIssue("Unstubbed ordinary sync call") {
        #expect(throws: UnexpectedInvocationError.self) { try mock.cachedName(id: "missing") }
    }
    await withKnownIssue("Unstubbed ordinary async call") {
        await #expect(throws: UnexpectedInvocationError.self) { try await mock.remoteName(id: "missing") }
    }
    #expect(mock.verify.cachedName(id: .equal("missing"), phase: .threw).wasCalled(.once).passed)
    #expect(mock.verify.remoteName(id: .equal("missing"), phase: .threw).wasCalled(.once).passed)
}
