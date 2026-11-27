import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Foundation

private struct ClosedRethrowsProvider: RethrowingDirectoryMockRethrowsBehavior {
    func apply(_ callback: (Int) throws -> String) rethrows -> String {
        FileHandle.standardError.write(Data("GEN015 RETHROWS PROVIDER BODY REACHED\n".utf8))
        fatalError("A finished session ran its rethrows provider")
    }
}

func verifyClosedRethrowsProvider() throws {
    let session = MockSession()
    let frozenHistory = StoredProperty<SessionSnapshot?>(nil)
    let reporter = FailureReporter { issue in
        let observed = session.snapshot()
        precondition(observed.isFinished && observed.events.isEmpty && observed.activeInvocationCount == 0)
        precondition(frozenHistory.get() == observed)
        precondition(issue.kind == .unexpectedCall)
        precondition(issue.endpoint.rawValue.contains(" rethrows"))
        FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
    }
    let mock = RethrowingDirectoryMock(
        failureReporter: reporter, session: session, rethrowsBehavior: ClosedRethrowsProvider()
    ) { stubs in
        stubs.label(for: .any).willReturn("unused")
    }
    let directory: any RethrowingDirectory = mock
    let callback: (Int) -> String = { _ in
        FileHandle.standardError.write(Data("GEN015 RETHROWS CALLBACK REACHED\n".utf8))
        fatalError("A finished rethrows witness invoked its caller's callback")
    }

    let finished = try session.finishIfQuiescent()
    precondition(finished.isFinished && finished.events.isEmpty && finished.activeInvocationCount == 0)
    frozenHistory.set(finished)
    _ = directory.apply(callback)
    fatalError("GEN015 CLOSED RETHROWS WITNESS RETURNED")
}
