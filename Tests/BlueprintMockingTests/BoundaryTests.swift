import Testing
import BlueprintMocking

@Test func RUN001_sameDiagnosticIdentityNeverSharesStorage() {
    let issues = Issues()
    let a = SyncStubbing<String, String>()
    let b = SyncStubbing<String, String>()
    a.matching(.any).willReturn("a")
    b.matching(.any).willReturn("b")
    let first = SyncEndpoint(id: EndpointID("same-display-name"), configuration: a.finish(),
                             failureReporter: issues.reporter)
    let second = SyncEndpoint(id: EndpointID("same-display-name"), configuration: b.finish(),
                              failureReporter: issues.reporter)
    #expect(first.invoke("x") == "a")
    #expect(second.verification(matching: .any).wasCalled(.never).passed)
    #expect(second.invoke("x") == "b")
    #expect(first.verification(matching: .any).wasCalled(.once).passed)
}

@Test func RUN_precedenceIsLastRegistrationWithoutSpecificityScoring() {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.equal("42")).willReturn("specific")
    stubs.matching(.any).willReturn("later")
    let endpoint = SyncEndpoint(id: EndpointID("precedence"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    #expect(endpoint.invoke("42") == "later")
}

@Test func RUN026_verificationFailureRetainsLocationAndPrefix() {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willReturn("ok")
    let endpoint = SyncEndpoint(id: EndpointID("count"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    _ = endpoint.invoke("42")
    let result = endpoint.verification(matching: .equal("missing")).wasCalled(
        .once, fileID: "Test/Example.swift", filePath: "/test/Example.swift", line: 17, column: 3)
    #expect(!result.passed)
    #expect(result.observed == 0)
    #expect(result.watermark == 1)
    #expect(issues.values.count == 1)
    #expect(issues.values[0].source.line == 17)
    #expect(issues.values[0].source.fileID == "Test/Example.swift")
    #expect(issues.values[0].kind == .verificationFailed)
    #expect(endpoint.verification(matching: .any).wasCalled(.atLeast(1)).passed)
    #expect(endpoint.verification(matching: .any).wasCalled(.atMost(1)).passed)
    // Verification is read-only; repeated observations do not consume calls.
    #expect(endpoint.verification(matching: .any).wasCalled(.once).passed)
}

@Test func RUN039_caughtMappedErrorStillReportsUnexpectedCall() async {
    let issues = Issues()
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("missing"), configuration: stubs.finish(),
                                        failureReporter: issues.reporter, failureMapping: { _ in .offline })
    do { _ = try await endpoint.invoke("42"); Issue.record("Expected mapped error") }
    catch { #expect(error == .offline) }
    #expect(issues.values.count == 1)
    #expect(issues.values[0].kind == .unexpectedCall)
    #expect(endpoint.invocations[0].phase == .threw)
    #expect(endpoint.verification(matching: .equal("42")).wasCalled(.once).passed)
}

@Test func RUN042_matcherAnswerAndReporterReenterWithoutLocks() {
    let issues = Issues()
    let nestedStubs = SyncStubbing<String, String>()
    nestedStubs.matching(.any).willReturn("nested")
    let nested = SyncEndpoint(id: EndpointID("nested"), configuration: nestedStubs.finish(),
                              failureReporter: issues.reporter)
    let stubs = SyncStubbing<String, String>()
    stubs.matching(Matcher { _ in nested.invoke("matcher") == "nested" })
        .willAnswer { _ in nested.invoke("answer") }
    let reporter = FailureReporter { issue in
        _ = nested.invoke("reporter")
        issues.reporter.report(issue)
    }
    let endpoint = SyncEndpoint(id: EndpointID("outer"), configuration: stubs.finish(),
                                failureReporter: reporter)
    #expect(endpoint.invoke("42") == "nested")
    #expect(!endpoint.verification(matching: .any).wasCalled(.never).passed)
    #expect(nested.verification(matching: .any).wasCalled(.exactly(3)).passed)
    #expect(issues.values.count == 1)
}

@Test func RUN026_verificationUsesFrozenPrefixWhilePredicateReenters() {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willReturn("ok")
    let endpoint = SyncEndpoint(id: EndpointID("prefix"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    _ = endpoint.invoke("before")
    let result = endpoint.verification(matching: Matcher { value in
        _ = endpoint.invoke("during")
        return value == "before"
    }).wasCalled(.once)
    #expect(result.passed)
    #expect(result.watermark == 1)
    #expect(result.invocationIDs == [1])
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(2)).passed)
}

@Test func RUN021_checkedSendableConcurrentAdmissionsAreUnique() async {
    let issues = Issues()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { $0 }
    let endpoint = SyncEndpoint(id: EndpointID("concurrent"), configuration: stubs.finish(),
                                failureReporter: issues.reporter)
    await withTaskGroup(of: Void.self) { group in
        for worker in 0..<8 {
            group.addTask {
                for step in 0..<125 {
                    let value = "\(worker)-\(step)"
                    #expect(endpoint.invoke(value) == value)
                }
            }
        }
    }
    let calls = endpoint.invocations
    #expect(calls.count == 1000)
    #expect(Set(calls.map(\.id)).count == 1000)
    #expect(calls.allSatisfy { $0.phase == .returned })
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(1000)).passed)
    #expect(issues.values.isEmpty)
}

private actor Suspension {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        let waiting = observers
        observers.removeAll()
        for observer in waiting { observer.resume() }
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

@Test func RUN036_outOfOrderCompletionRetainsAdmissionIdentity() async throws {
    let firstGate = Suspension()
    let secondGate = Suspension()
    let issues = Issues()
    let stubs = AsyncThrowingStubbing<String, String, ServiceError>()
    stubs.matching(.any).willAnswer { value async throws(ServiceError) in
        if value == "first" { await firstGate.suspend() }
        else { await secondGate.suspend() }
        return value
    }
    let endpoint = AsyncThrowingEndpoint(id: EndpointID("suspended"), configuration: stubs.finish(),
                                        failureReporter: issues.reporter)
    let first = Task { try await endpoint.invoke("first") }
    await firstGate.waitForEntry()
    let second = Task { try await endpoint.invoke("second") }
    await secondGate.waitForEntry()
    #expect(endpoint.verification(matching: .any).wasCalled(.exactly(2)).passed)
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.never).passed)
    await secondGate.release()
    #expect(try await second.value == "second")
    #expect(endpoint.invocations[0].phase == .admitted)
    #expect(endpoint.invocations[1].phase == .returned)
    await firstGate.release()
    #expect(try await first.value == "first")
    #expect(endpoint.invocations.map(\.id) == [1, 2])
    #expect(endpoint.verification(matching: .any, phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(issues.values.isEmpty)
}
