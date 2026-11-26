import Testing
@testable import BlueprintMocking

enum ServiceError: Error, Sendable { case offline }

final class Issues: Sendable {
    private let state = CriticalState<[MockIssue]>([])
    var values: [MockIssue] { state.withLock { $0 } }
    var reporter: FailureReporter {
        FailureReporter { [self] issue in state.withLock { $0.append(issue) } }
    }
}

@Test func RUN002_configurationAndVerificationNeverInvokeWitness() {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.equal("42")).willReturn("Ada")
    let endpoint = SyncEndpoint(id: EndpointID("lookup"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    #expect(endpoint.verification(matching: .any).wasCalled(.never).passed)
    #expect(endpoint.invoke("42") == "Ada")
    #expect(endpoint.verification(matching: .equal("42")).wasCalled(.once).passed)
    #expect(issues.values.isEmpty)
}

@Test func RUN003_typedAsyncReturnThrowAndAnswer() async throws {
    let issues = Issues()
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.equal("return")).willReturn("Ada")
    stubs.matching(.equal("throw")).willThrow(.offline)
    stubs.matching(.equal("answer")).willAnswer { value async throws(ServiceError) in
        value.uppercased()
    }
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("fetch"), configuration: stubs.finish(),
                                        failureReporter: issues.reporter)
    #expect(try await endpoint.invoke("return") == "Ada")
    do { _ = try await endpoint.invoke("throw"); Issue.record("Expected offline") }
    catch { #expect(error == .offline) }
    #expect(try await endpoint.invoke("answer") == "ANSWER")
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(3)).passed)
    #expect(endpoint.verification(matching: .any, phase: .threw).wasCalled(.once).passed)
    #expect(issues.values.isEmpty)
}
