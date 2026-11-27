import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles
import Testing

@Test func GEN036_generatedIsolatedAnswerRunsOnOriginalActorAndVerifiesIdentity() async throws {
    let session = MockSession()
    let first = IsolatedDirectoryWorker()
    let second = IsolatedDirectoryWorker()
    let mock = IsolatedActorDirectoryMock(
        failureReporter: FailureReporter { Issue.record("\($0.message)") }, session: session
    ) { stubs in
        stubs.sample(.identical(to: first)).willAnswer { (worker: isolated IsolatedDirectoryWorker) in
            #expect(session.snapshot().activeInvocationCount == 1)
            worker.increment()
            return worker.count
        }
        stubs.sample(.identical(to: second)).willReturn(42)
        stubs.label(for: .equal("ordinary")).willReturn("ordinary member remains available")
    }
    let directory: any IsolatedActorDirectory = mock
    let fromDetached = await Task.detached { await directory.sample(first) }.value
    let fromOwner = await first.sampleOnOwner(using: directory)
    let constant = await directory.sample(second)
    let count = await first.count
    let otherCount = await second.count

    #expect(fromDetached == 1)
    #expect(fromOwner == 2)
    #expect(constant == 42)
    #expect(count == 2 && otherCount == 0)
    #expect(mock.verify.sample(.identical(to: first), phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.sample(.identical(to: second), phase: .returned).wasCalled(.once).passed)
    #expect(directory.label(for: "ordinary") == "ordinary member remains available")

    let completed = session.snapshot()
    #expect(completed.events.map(\.phase) == [.admitted, .returned, .admitted, .returned,
                                             .admitted, .returned, .admitted, .returned])
    let selected = completed.events.first?.endpoint
    #expect(selected?.rawValue.contains("isolated ConsumerDomain.IsolatedDirectoryWorker") == true)
    #expect(completed.events.prefix(6).allSatisfy { $0.endpoint == selected })
    #expect(completed.activeInvocationCount == 0)
}
