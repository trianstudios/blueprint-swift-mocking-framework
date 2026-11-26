import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

@Test func GEN022_propertyGetAndSetHaveIndependentHandlersAndHistories() {
    let mock = PropertyDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.get_title().willReturn("original")
        stubs.set_title(.equal("proposed")).willReturn(())
    }
    var screen = PropertyScreen(directory: mock)

    #expect(mock.verify.get_title().wasCalled(.never).passed)
    #expect(mock.verify.set_title(.any).wasCalled(.never).passed)
    #expect(screen.title() == "original")
    #expect(mock.verify.get_title(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_title(.any).wasCalled(.never).passed)

    screen.setTitle("proposed")
    #expect(mock.verify.set_title(.equal("proposed"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.set_title(.equal("other")).wasCalled(.never).passed)
    #expect(mock.verify.get_title().wasCalled(.once).passed)
    #expect(screen.title() == "original")
    #expect(mock.verify.get_title().wasCalled(.exactly(2)).passed)
}

@Test func RUN039_unstubbedPropertySetterReportsIssueAndReturnsVoid() {
    let mock = PropertyDirectoryMock(failureReporter: .swiftTesting) { _ in }
    var screen = PropertyScreen(directory: mock)

    withKnownIssue("Unstubbed property setter") {
        screen.setTitle("proposed")
    }

    #expect(mock.verify.set_title(.equal("proposed")).wasCalled(.once).passed)
    #expect(mock.verify.get_title().wasCalled(.never).passed)
}

@Test func GEN023_asyncPropertyGetterReturnsThroughTypedConsumer() async throws {
    let mock = PropertyDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.get_summary().willReturn("ready")
    }
    let screen = PropertyScreen(directory: mock)

    #expect(mock.verify.get_summary().wasCalled(.never).passed)
    let summary = try await screen.summary()
    #expect(summary == "ready")
    #expect(mock.verify.get_summary(phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_title().wasCalled(.never).passed)
    #expect(mock.verify.set_title(.any).wasCalled(.never).passed)
}

@Test func GEN023_asyncPropertyGetterPreservesDeclaredError() async {
    let mock = PropertyDirectoryMock(failureReporter: .swiftTesting) { stubs in
        stubs.get_summary().willThrow(.unavailable)
    }
    let screen = PropertyScreen(directory: mock)

    do {
        _ = try await screen.summary()
        Issue.record("Expected PropertyFailure.unavailable")
    } catch {
        #expect(error == .unavailable)
    }
    #expect(mock.verify.get_summary(phase: .threw).wasCalled(.once).passed)
}
