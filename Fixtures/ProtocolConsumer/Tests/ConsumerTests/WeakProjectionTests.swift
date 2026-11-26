import BlueprintMocking
import BlueprintMockingTesting
import Testing

private final class ProjectionRecord: Sendable {
    let label: StoredProperty<String>

    init(label: String) {
        self.label = StoredProperty(label)
    }
}

private struct WeakArgumentSnapshot: Sendable {
    let reference: WeakProjectedReference<ProjectionRecord>
    let label: String
}

@Test func RUN009_weakProjectedReferencesDoNotRetainMutableRecords() throws {
    let session = MockSession()
    let stubs = SyncStubbing<ProjectionRecord, ProjectionRecord>()
    stubs.matching(.any).willAnswer { $0 }
    let projection = InvocationProjection(
        argument: { (record: ProjectionRecord) in
            WeakArgumentSnapshot(reference: WeakProjectedReference(record), label: record.label.get())
        },
        result: { (record: ProjectionRecord) in WeakProjectedReference(record) }
    )
    let endpoint = ProjectedSyncEndpoint(
        id: EndpointID("store"), configuration: stubs.finish(), projection: projection,
        failureReporter: .swiftTesting, scope: session.makeMock()
    )

    func captureWhileAlive() throws -> ProjectedInvocation<WeakArgumentSnapshot, WeakProjectedReference<ProjectionRecord>> {
        let record = ProjectionRecord(label: "initial")
        #expect(endpoint.invoke(record) === record)
        let entry = try #require(endpoint.projectedHistory().calls.first)
        guard case .value(let argument) = entry.argument, case .value(let result) = entry.result else {
            Issue.record("Expected both fields to be projected")
            return entry
        }

        record.label.set("mutated")
        #expect(argument.label == "initial")
        #expect(argument.reference.object === record)
        #expect(result.object === record)
        #expect(result.object?.label.get() == "mutated")
        return entry
    }

    let captured = try captureWhileAlive()
    guard case .value(let argument) = captured.argument, case .value(let result) = captured.result else {
        Issue.record("Expected captured weak reference values")
        return
    }
    // A released referent does not change either projection's history status.
    #expect(argument.reference.object == nil)
    #expect(result.object == nil)
    #expect(argument.label == "initial")

    let history = endpoint.projectedHistory()
    let current = try #require(history.calls.first)
    guard case .value(let currentArgument) = current.argument, case .value(let currentResult) = current.result else {
        Issue.record("A released weak referent must leave a captured projection, not an unavailable field")
        return
    }
    #expect(currentArgument.reference.object == nil)
    #expect(currentResult.object == nil)
    #expect(currentArgument.label == "initial")
    #expect(current.phase == .returned)
    #expect(current.epoch == captured.epoch)
    #expect(current.id == captured.id)
    #expect(current.configurationRevision == captured.configurationRevision)
    #expect(current.sessionInvocationID == captured.sessionInvocationID)
    #expect(session.snapshot().events.map(\.invocationID) == [
        captured.sessionInvocationID, captured.sessionInvocationID,
    ])
}
