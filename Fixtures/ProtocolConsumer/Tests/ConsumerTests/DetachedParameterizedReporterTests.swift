import Foundation
import Testing
import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDoubles

private struct ParameterizedReporterGate: Sendable {
    struct ActivePeer: Sendable {
        let testID: Test.ID
        let sessionID: SessionID
    }

    let peerIsActive = AsyncStream<ActivePeer>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let ownerFinished = AsyncStream<Void>.makeStream()
}

private typealias ParameterizedIssueCollector = (
    stream: AsyncStream<MockIssue>,
    continuation: AsyncStream<MockIssue>.Continuation
)

private let explicitReporterGate = ParameterizedReporterGate()

// The isolated native runner expects a single issue assigned to owner-A.
@Test(.timeLimit(.minutes(1)), arguments: ["owner-A", "peer-B"])
func DX023_detachedParameterizedReporterAttribution(_ scenario: String) async throws {
    guard parameterizedReporterProbeIsEnabled else { return }
    try await checkDetachedParameterizedReporter(
        scenario, gate: explicitReporterGate, issues: AsyncStream<MockIssue>.makeStream()
    )
}

private var parameterizedReporterProbeIsEnabled: Bool {
    ProcessInfo.processInfo.environment["BLUEPRINT_EXPECT_PARAMETERIZED_REPORTER_FAILURE"] == "1"
}

private func checkDetachedParameterizedReporter(
    _ scenario: String,
    gate: ParameterizedReporterGate,
    issues: ParameterizedIssueCollector
) async throws {
    let isPeer = scenario == "peer-B"
    defer {
        if isPeer { gate.peerIsActive.continuation.finish() }
        else { gate.ownerFinished.continuation.finish() }
    }
    let nativeID = try #require(Test.current?.id)
    try #require(Test.Case.current?.isParameterized == true)

    let session = MockSession()
    let scope = TypeSubscriptDirectoryMock.makeTypeScope(
        failureReporter: FailureReporter { issues.continuation.yield($0) }, session: session
    ) { stubs in
        stubs.set_subscript(.equal(7), newValue: .equal(1)).willReturn(())
    }
    if isPeer {
        let baseline = await scope.withValue {
            TypeSubscriptDirectoryMock[7] = 1
            let baseline = session.snapshot()
            var owner = gate.ownerFinished.stream.makeAsyncIterator()
            print("BLUEPRINT_PARAM_PEER_ACTIVE id=\(nativeID)")
            gate.peerIsActive.continuation.yield(.init(testID: nativeID, sessionID: session.id))
            gate.peerIsActive.continuation.finish()
            _ = await owner.next()
            return baseline
        }
        issues.continuation.finish()
        var received = issues.stream.makeAsyncIterator()
        try #require(await received.next() == nil)
        try #require(baseline.events.map(\.phase) == [.admitted, .returned])
        try #require(session.snapshot() == baseline)
        print("PASS: DX023 peer case drained 0 issues")
        return
    }

    var peer = gate.peerIsActive.stream.makeAsyncIterator()
    let activePeer = try #require(await peer.next())
    try #require(activePeer.testID == nativeID)
    try #require(activePeer.sessionID != session.id)
    print("BLUEPRINT_PARAM_OWNER_ACTIVE id=\(nativeID)")
    let wasDetached = await Task.detached {
        let noNativeContext = Test.current == nil && Test.Case.current == nil
        scope.withValue { TypeSubscriptDirectoryMock[7] = 2 }
        return noNativeContext
    }.value
    try #require(wasDetached)
    let ownerSnapshot = session.snapshot()
    try #require(ownerSnapshot.events.map(\.phase) == [.admitted, .returned])
    try #require(scope.verify.set_subscript(.equal(7), newValue: .equal(2), phase: .returned).wasCalled(.once).passed)

    issues.continuation.finish()
    var received = issues.stream.makeAsyncIterator()
    let issue = try #require(await received.next())
    try #require(await received.next() == nil)
    try #require(issue.kind == .unexpectedCall)
    try #require(issue.message.hasPrefix("No matching stub for "))
    try #require(Test.current?.id == nativeID)
    try #require(Test.Case.current?.isParameterized == true)
    FailureReporter.swiftTesting.report(issue)
    print("PASS: DX023 owner case drained 1 detached issue")
}

#if compiler(>=6.1)
private let scopedReporterGate = ParameterizedReporterGate()

private struct ParameterizedReporterCollectorTrait: TestTrait, TestScoping {
    @TaskLocal static var issues: ParameterizedIssueCollector?

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing body: @Sendable () async throws -> Void
    ) async throws {
        let collector = AsyncStream<MockIssue>.makeStream()
        defer { collector.continuation.finish() }
        #if compiler(>=6.2)
        let operation: nonisolated(nonsending) () async throws -> Void = { try await body() }
        try await Self.$issues.withValue(collector, operation: operation)
        #else
        try await Self.$issues.withValue(collector, operation: body)
        #endif
    }
}

@Test(ParameterizedReporterCollectorTrait(), .timeLimit(.minutes(1)), arguments: ["owner-A", "peer-B"])
func DX023_scopedParameterizedReporterAttribution(_ scenario: String) async throws {
    guard parameterizedReporterProbeIsEnabled else { return }
    let issues = try #require(ParameterizedReporterCollectorTrait.issues)
    try await checkDetachedParameterizedReporter(scenario, gate: scopedReporterGate, issues: issues)
}
#endif
