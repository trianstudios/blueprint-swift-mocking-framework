import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

@Test func GEN014_throwsNeverNeedsNoTry() async {
    let mock = EffectEdgesMock(failureReporter: .swiftTesting) { stubs in
        stubs.read(id: .any).willReturn("sync")
        stubs.readAsync(id: .any).willAnswer { _ in
            await Task.yield()
            return "async"
        }
    }
    #expect(mock.read(id: "item") == "sync")
    #expect(await mock.readAsync(id: "item") == "async")
    #expect(mock.verify.read(id: .equal("item"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.readAsync(id: .equal("item"), phase: .returned).wasCalled(.once).passed)
}

@Test func RUN039_unstubbedVoidReportsAndReturns() async {
    let mock = EffectEdgesMock(failureReporter: .swiftTesting) { stubs in
        stubs.record(id: .equal("handled")).willReturn(())
        stubs.flush(id: .equal("handled")).willReturn(())
    }
    mock.record(id: "handled")
    await mock.flush(id: "handled")
    withKnownIssue("Unstubbed synchronous Void call") {
        mock.record(id: "missing")
    }
    await withKnownIssue("Unstubbed asynchronous Void call") {
        await mock.flush(id: "missing")
    }
    #expect(mock.verify.record(id: .equal("missing"), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.flush(id: .equal("missing"), phase: .returned).wasCalled(.once).passed)
}
