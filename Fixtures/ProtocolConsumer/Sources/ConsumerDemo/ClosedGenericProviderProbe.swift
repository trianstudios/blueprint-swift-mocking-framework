import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Foundation

private struct ClosedGenericProvider: GenericProviderDirectoryMockBehavior {
    func transform<Value: Hashable & Sendable>(_ value: Value) -> Value {
        FileHandle.standardError.write(Data("GEN011 PROVIDER BODY REACHED\n".utf8))
        fatalError("A finished session ran its generic provider")
    }
}

func verifyClosedGenericProvider() throws {
    let session = MockSession()
    let frozenHistory = StoredProperty<SessionSnapshot?>(nil)
    let reporter = FailureReporter { issue in
        let observed = session.snapshot()
        precondition(observed.isFinished && observed.events.isEmpty && observed.activeInvocationCount == 0)
        precondition(frozenHistory.get() == observed)
        precondition(issue.kind == .unexpectedCall)
        precondition(issue.endpoint.specialization?.typeName == String(reflecting: Int.self))
        FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
    }
    let mock = GenericProviderDirectoryMock(
        failureReporter: reporter, session: session, genericBehavior: ClosedGenericProvider()
    ) { stubs in
        stubs.label(for: .any).willReturn("unused")
    }
    let directory: any GenericProviderDirectory = mock

    let finished = try session.finishIfQuiescent()
    precondition(finished.isFinished && finished.events.isEmpty && finished.activeInvocationCount == 0)
    frozenHistory.set(finished)
    _ = directory.transform(Int(17))
    fatalError("GEN011 CLOSED WITNESS RETURNED")
}
