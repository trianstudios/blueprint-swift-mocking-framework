import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles

private struct VariadicWrite: Equatable, Sendable {
    let field: String
    let indices: [Int]
    let value: String
}

@Test func GEN024_variadicSubscriptPreservesPackedGetSetAndReadModifyWrite() throws {
    let session = MockSession()
    let reads = ArgumentCaptor<[Int]>(session: session)
    let writes = ArgumentCaptor<VariadicWrite>(session: session)
    let mock = VariadicSubscriptDirectoryMock(failureReporter: .swiftTesting, session: session) { stubs in
        stubs.get_subscript(field: .equal("title"), .any)
            .capturing(into: reads, projecting: { $0.1 })
            .willAnswer { input in input.1.isEmpty ? "empty" : "draft" }
        stubs.set_subscript(field: .equal("title"), .any, newValue: .any)
            .capturing(into: writes, projecting: { VariadicWrite(field: $0.0, indices: $0.1, value: $0.2) })
            .willReturn(())
    }
    var client = VariadicSubscriptClient(directory: mock)
    #expect(client.emptyLabel() == "empty")
    client.storeEmptyLabel()
    let checkpoint = session.checkpoint()
    client.reviseOrderedLabel()

    #expect(reads.captures.map(\.value) == [[], [4, 2, 4]])
    #expect(writes.captures.map(\.value) == [
        VariadicWrite(field: "title", indices: [], value: "inbox"),
        VariadicWrite(field: "title", indices: [4, 2, 4], value: "draft!"),
    ])
    #expect(mock.verify.get_subscript(field: .equal("title"), .equal([4, 2, 4])).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(field: .equal("title"), .equal([2, 4, 4])).wasCalled(.never).passed)
    #expect(mock.verify.set_subscript(field: .equal("title"), .equal([4, 2, 4]), newValue: .equal("draft!"),
                                     phase: .returned).wasCalled(.once).passed)

    let events = try session.events(since: checkpoint)
    #expect(events.map(\.phase) == [.admitted, .returned, .admitted, .returned])
    #expect(events.filter { $0.phase == .admitted }.map(\.endpoint.rawValue) == [
        "schema1|ConsumerDomain.VariadicSubscriptDirectory|subscript:(field:String,_:Int...).get->String|Sendable",
        "schema1|ConsumerDomain.VariadicSubscriptDirectory|subscript:(field:String,_:Int...).set(field:String,_:Int...,newValue:String)->Void|Sendable",
    ])
}

@Test func GEN024_variadicReadOnlySubscriptRetainsItsTypedAsyncEffect() async throws {
    let mock = VariadicSubscriptDirectoryMock(
        failureReporter: .swiftTesting,
        failureMappings: .init { mappings in
            mappings.get_subscript(remote: String.self, [Int].self) { issue in
                #expect(issue.kind == .unexpectedCall)
                return .unavailable
            }
        }
    ) { stubs in
        stubs.get_subscript(remote: .equal("east"), .equal([6, 3, 6]))
            .willAnswer { input async throws(VariadicSubscriptFailure) in
                await Task.yield()
                return input.0 + ":" + input.1.map(String.init).joined(separator: ",")
            }
    }
    let client = VariadicSubscriptClient(directory: mock)
    #expect(try await client.remoteNames() == "east:6,3,6")
    await withKnownIssue("An unstubbed variadic getter reports before mapping its typed error") {
        await #expect(throws: VariadicSubscriptFailure.unavailable) { try await client.remoteWithoutIndices() }
    }
    #expect(mock.verify.get_subscript(remote: .equal("east"), .equal([6, 3, 6]),
                                     phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.get_subscript(remote: .equal("east"), .equal([]),
                                     phase: .threw).wasCalled(.once).passed)
}
