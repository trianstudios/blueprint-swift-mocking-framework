import Foundation
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func SYS001_generatedProtocolWorkflow() async throws {
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.fetchUser(id: .equal("42")).willReturn("Ada")
        stubs.greeting(for: .any).willReturn("Hello")
    }
    #expect(mock.verify.fetchUser(id: .any).wasCalled(.never).passed)
    #expect(try await UserService(repository: mock).load(id: "42") == "Ada")
    #expect(mock.verify.fetchUser(id: .equal("42")).wasCalled(.once).passed)
    #expect(mock.greeting(for: "Ada") == "Hello")
    #expect(mock.verify.greeting(for: .equal("Ada")).wasCalled(.once).passed)
}

@Test func LANG_typedErrorSurvivesGeneratedWitness() async {
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.fetchUser(id: .any).willThrow(.offline)
    }
    do { _ = try await UserService(repository: mock).load(id: "42"); Issue.record("Expected offline") }
    catch { #expect(error == .offline) }
    #expect(mock.verify.fetchUser(id: .any, phase: .threw).wasCalled(.once).passed)
}

@Test @MainActor func ISOLATION_sendableMockInjectedIntoMainActorConsumer() async throws {
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.fetchUser(id: .any).willReturn("Ada")
    }
    let model = UserViewModel(repository: mock)
    try await model.load(id: "42")
    #expect(model.name == "Ada")
    #expect(mock.verify.fetchUser(id: .equal("42")).wasCalled(.once).passed)
}

// Invoked separately by scripts/verify.py; normal consumer tests remain green.
@Test func DX022_intentionalReporterFailure() {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_EXPECT_FAILURE"] == "1" else { return }
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { _ in }
    mock.verify.greeting(for: .any).wasCalled(.once)
}

@Test func RUN001_overloadLabelsRouteToIndependentEndpoints() {
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.greeting(for: .any).willReturn("labeled")
        stubs.greeting(.any).willReturn("unlabeled")
    }
    #expect(mock.greeting(for: "Ada") == "labeled")
    #expect(mock.verify.greeting(.any).wasCalled(.never).passed)
    #expect(mock.greeting("Ada") == "unlabeled")
    #expect(mock.verify.greeting(for: .any).wasCalled(.once).passed)
    #expect(mock.verify.greeting(.any).wasCalled(.once).passed)
}

private actor SequenceAnswer {
    private var calls = 0

    func name(for id: String) -> String {
        calls += 1
        return "User \(id), response \(calls)"
    }
}

@Test func RUN012_generatedTypedSequenceRepeatsItsLastAnswerThroughTheService() async throws {
    let answer = SequenceAnswer()
    let mock = UserRepositoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.fetchUser(id: .equal("42")).willSequence(
            .throwing(.offline),
            .returning("Cached Ada"),
            .answering { id async throws(RepositoryError) in
                await answer.name(for: id)
            },
            policy: .repeatLast
        )
    }
    let service = UserService(repository: mock)

    do throws(RepositoryError) {
        _ = try await service.load(id: "42")
        Issue.record("Expected the first sequence step to throw RepositoryError.offline")
    } catch {
        #expect(error == .offline)
    }
    #expect(try await service.load(id: "42") == "Cached Ada")
    #expect(try await service.load(id: "42") == "User 42, response 1")
    #expect(try await service.load(id: "42") == "User 42, response 2")

    let admitted = mock.verify.fetchUser(id: .equal("42")).wasCalled(.exactly(4))
    let thrown = mock.verify.fetchUser(id: .equal("42"), phase: .threw).wasCalled(.once)
    let returned = mock.verify.fetchUser(id: .equal("42"), phase: .returned).wasCalled(.exactly(3))
    #expect(admitted.passed && thrown.passed && returned.passed)
    #expect(thrown.invocationIDs == Array(admitted.invocationIDs.prefix(1)))
    #expect(returned.invocationIDs == Array(admitted.invocationIDs.dropFirst()))
}
