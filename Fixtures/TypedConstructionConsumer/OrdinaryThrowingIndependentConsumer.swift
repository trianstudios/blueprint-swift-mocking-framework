import BlueprintMocking
import OrdinaryThrowingConstructorDomain

private typealias Mock = OrdinaryThrowingConstructionDirectoryMock
private struct ClientFailure: Error, Equatable { let seed: Int }

@main struct OrdinaryThrowingIndependentConsumer {
    static func main() async throws {
        if let mode = CommandLine.arguments.dropFirst().first {
            try await checkMissingContext(detached: mode == "unbound-detached")
            return
        }
        try checkConfiguredResults()
        try checkRejectedBoundScopes()
        print("PASS: GEN026 ordinary throwing construction preserves configured errors and reports rejected scopes")
    }

    private static func checkConfiguredResults() throws {
        let session = MockSession()
        let scope = Mock.makeConstructionScope(
            failureReporter: FailureReporter { issue in preconditionFailure("Unexpected report: \(issue.message)") },
            session: session
        ) { seed, stubs in
            precondition(session.snapshot().activeInvocationCount == 1)
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
            if seed < 0 { throw ClientFailure(seed: seed) }
        }
        let before = session.makeMock().id
        do {
            _ = try scope.withValue { try createOrdinaryThrowingDirectory(Mock.self, seed: -9) }
            preconditionFailure("Configured failure returned an instance")
        } catch let error as ClientFailure {
            precondition(error == ClientFailure(seed: -9))
        }
        let events = session.snapshot().events
        precondition(events.map(\.phase) == [.admitted, .threw])
        precondition(events[0].invocationID == events[1].invocationID)
        precondition(events[0].mockID == events[1].mockID)
        precondition(events.allSatisfy { $0.constructedMockID == nil })
        precondition(session.makeMock().id.rawValue == before.rawValue + 1)

        let instance = try scope.withValue { try createOrdinaryThrowingDirectory(Mock.self, seed: 13) }
        precondition(instance.label(2) == "13/2")
        precondition(instance.verify.label(.equal(2), phase: .returned).wasCalled(.once).passed)
        let all = session.snapshot().events
        precondition(all.map(\.phase) == [.admitted, .threw, .admitted, .returned, .admitted, .returned])
        precondition(all[2].invocationID == all[3].invocationID)
        precondition(all[2].mockID == all[3].mockID)
        precondition(all[3].mockID != all[5].mockID && all[3].constructedMockID == all[5].mockID)
        precondition(all[3].endpoint.rawValue.contains("|init(seed:Swift.Int) throws->Self|"))
    }

    private static func checkRejectedBoundScopes() throws {
        let delivered = StoredProperty<[MockIssue]>([])
        let reporter = FailureReporter { delivered.set(delivered.get() + [$0]) }
        let stale = MockSession()
        let staleScope = Mock.makeConstructionScope(failureReporter: reporter, session: stale) { _, _ in
            preconditionFailure("Stale construction ran setup")
        }
        _ = try stale.resetHistory()
        let reset = stale.snapshot()
        do {
            _ = try staleScope.withValue { try createOrdinaryThrowingDirectory(Mock.self, seed: 1) }
            preconditionFailure("Stale construction returned an instance")
        } catch let error as UnexpectedInvocationError {
            checkIssue(error.issue, "stale type-level mock scope")
            precondition(delivered.get().count == 1 && delivered.get().first?.message == error.issue.message)
        }
        precondition(stale.snapshot() == reset)

        let orphans = OrphanFailureBuffer()
        let finished = MockSession(orphanFailures: orphans)
        let finishedScope = Mock.makeConstructionScope(failureReporter: reporter, session: finished) { _, _ in
            preconditionFailure("Finished construction ran setup")
        }
        let closed = try finished.finishIfQuiescent()
        do {
            _ = try finishedScope.withValue { try createOrdinaryThrowingDirectory(Mock.self, seed: 2) }
            preconditionFailure("Finished construction returned an instance")
        } catch let error as UnexpectedInvocationError {
            checkIssue(error.issue, "finished mock session")
            precondition(delivered.get().count == 1)
            let buffered = orphans.drain()
            precondition(buffered.failures.count == 1 && buffered.droppedCount == 0)
            precondition(buffered.failures[0].epoch == closed.epoch)
            precondition(buffered.failures[0].issue.message == error.issue.message)
        }
        precondition(finished.snapshot() == closed)
    }

    private static func checkMissingContext(detached: Bool) async throws {
        let session = MockSession()
        let scope = Mock.makeConstructionScope(
            failureReporter: FailureReporter { _ in preconditionFailure("Unbound failure was attached to an owner") },
            session: session
        ) { _, _ in preconditionFailure("Unbound construction ran setup") }
        let before = session.snapshot()
        do {
            if detached {
                _ = try await scope.withValue {
                    try await Task.detached { try createOrdinaryThrowingDirectory(Mock.self, seed: 3) }.value
                }
            } else {
                _ = try createOrdinaryThrowingDirectory(Mock.self, seed: 3)
            }
            preconditionFailure("Missing scope returned an instance")
        } catch let error as UnexpectedInvocationError {
            checkIssue(error.issue, "Missing type-level mock scope")
        }
        precondition(session.snapshot() == before)
        print("PASS: missing ordinary throwing scope reports once and throws")
    }

    private static func checkIssue(_ issue: MockIssue, _ message: String) {
        precondition(issue.kind == .unexpectedCall && issue.message.contains(message))
        precondition(issue.endpoint.rawValue.contains("|init(seed:Swift.Int) throws->Self|"))
        precondition(issue.source.line == 2 && issue.source.filePath == "OrdinaryThrowingConstructorDomain.swift")
    }
}
