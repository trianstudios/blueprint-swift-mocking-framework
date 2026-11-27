import Foundation
import Testing
@testable import BlueprintMocking

private struct ExportedTrace: Decodable {
    struct Omission: Decodable, Equatable {
        let count: Int
        let firstOrdinal: String
        let lastOrdinal: String
    }

    struct Record: Decodable {
        let ordinal: String
        let elapsedSeconds: String
        let elapsedAttoseconds: String
        let mockID: String
        let invocationID: String
        let configurationRevision: String
        let kind: String
        let origin: String?
        let endpoint: String
        let endpointTruncated: Bool
        let specialized: Bool
    }

    let schemaVersion: Int
    let sessionID: String
    let epoch: String
    let watermark: String
    let activeInvocationCount: Int
    let isFinished: Bool
    let payloads: String
    let prunedThrough: String?
    let cancellationRequestsPrunedThrough: String?
    let omitted: Omission?
    let records: [Record]
}

private func decoded(_ snapshot: SessionSnapshot, maximumRecords: Int = 128) throws -> ExportedTrace {
    try JSONDecoder().decode(ExportedTrace.self, from: snapshot.exportTraceJSON(maximumRecords: maximumRecords))
}

private func recordingEndpoint(_ name: String, in session: MockSession) -> SyncEndpoint<Int, Int> {
    let setup = SyncStubbing<Int, Int>()
    setup.matching(.any).willAnswer { $0 }
    return SyncEndpoint(
        id: EndpointID(name), configuration: setup.finish(),
        failureReporter: FailureReporter { _ in Issue.record("Unexpected trace fixture issue") },
        scope: session.makeMock()
    )
}

@Test func DX027_traceDistinguishesPrunedHistoryFromTheExportWindow() throws {
    let session = MockSession(clock: .manual)
    let empty = try decoded(session.snapshot(), maximumRecords: 0)
    #expect(empty.schemaVersion == 1)
    #expect(empty.sessionID == session.id.rawValue.uuidString)
    #expect(empty.epoch == "0")
    #expect(empty.watermark == "0")
    #expect(empty.payloads == "omitted")
    #expect(empty.records.isEmpty)
    #expect(empty.prunedThrough == nil)
    #expect(empty.cancellationRequestsPrunedThrough == nil)
    #expect(empty.omitted == nil)

    let endpoint = recordingEndpoint("timeline", in: session)
    _ = endpoint.invoke(1)
    let discarded = session.checkpoint()
    try session.discardEvents(through: discarded)
    let fullyPruned = try decoded(session.snapshot())
    #expect(fullyPruned.records.isEmpty)
    #expect(fullyPruned.prunedThrough == "2")
    #expect(fullyPruned.omitted == nil)
    #expect(try session.verifyNoInteractions(in: .session).outcome == .historyUnavailable)

    try session.advanceClock(by: .nanoseconds(7))
    for value in 2...4 { _ = endpoint.invoke(value) }
    let snapshot = session.snapshot()
    let bytes = try snapshot.exportTraceJSON(maximumRecords: 3)
    let trace = try JSONDecoder().decode(ExportedTrace.self, from: bytes)
    #expect(try snapshot.exportTraceJSON(maximumRecords: 3) == bytes)
    #expect(trace.prunedThrough == "2")
    #expect(trace.cancellationRequestsPrunedThrough == nil)
    #expect(trace.omitted == .init(count: 3, firstOrdinal: "3", lastOrdinal: "5"))
    #expect(trace.records.map(\.ordinal) == ["6", "7", "8"])
    #expect(trace.records.map(\.kind) == ["returned", "admitted", "returned"])
    #expect(trace.records.map(\.elapsedAttoseconds) == Array(repeating: "7000000000", count: 3))
    #expect(trace.records.map(\.configurationRevision) == ["0", "0", "0"])
    #expect(trace.records.allSatisfy { $0.endpoint == "timeline" && !$0.endpointTruncated })

    let zero = try decoded(snapshot, maximumRecords: 0)
    #expect(zero.records.isEmpty)
    #expect(zero.omitted == .init(count: 6, firstOrdinal: "3", lastOrdinal: "8"))
    #expect(throws: SessionTraceExportError.invalidRecordLimit) {
        try snapshot.exportTraceJSON(maximumRecords: -1)
    }
    #expect(throws: SessionTraceExportError.invalidRecordLimit) {
        try snapshot.exportTraceJSON(maximumRecords: 257)
    }
}

@Test func DX027_archivedTracePreservesOriginalEpochAndGaps() throws {
    let session = MockSession(clock: .manual)
    let reporter = FailureReporter { _ in Issue.record("Unexpected archived trace fixture issue") }
    let current = recordingEndpoint("new epoch", in: session)
    let setup = SyncThrowingStubbing<Int, SessionSnapshot, SessionResetError>()
    setup.matching(.any).willAnswer { _ throws(SessionResetError) in
        let beforeReset = session.snapshot()
        _ = try session.resetHistory(.detachActive)
        _ = current.invoke(7)
        return beforeReset
    }
    let original = SyncThrowingEndpoint(
        id: EndpointID("old epoch"), configuration: setup.finish(), failureReporter: reporter,
        scope: session.makeMock()
    )

    let admitted = try original.invoke(3)
    let old = try #require(session.snapshot(epoch: admitted.epoch))
    let frozen = try decoded(admitted)
    let archived = try decoded(old)
    let newest = try decoded(session.snapshot())
    #expect(frozen.records.map(\.ordinal) == ["1"])
    #expect(frozen.activeInvocationCount == 1)
    #expect(frozen.watermark == "1")
    #expect(archived.records.map(\.ordinal) == ["1", "4"])
    #expect(archived.records.map(\.kind) == ["admitted", "returned"])
    #expect(archived.records.map(\.invocationID) == ["1", "1"])
    #expect(archived.epoch == "0")
    #expect(archived.activeInvocationCount == 0)
    #expect(archived.watermark == "4")
    #expect(archived.omitted == nil)
    #expect(archived.prunedThrough == nil)
    #expect(newest.records.map(\.ordinal) == ["2", "3"])
    #expect(newest.epoch == "1")
    #expect(newest.watermark == "4")
    #expect(newest.prunedThrough == nil)
    #expect(newest.omitted == nil)
}

@Test func DX027_traceMergesCancellationRequestsWithTerminalRowsAndKeepsSeparatePruning() throws {
    let session = MockSession(clock: .manual)
    let scope = session.makeMock()
    let admission = session.withLock {
        $0.admit(mockID: scope.id, endpoint: EndpointID("cancel"), configurationRevision: RuleRevision(rawValue: 11))
    }
    try session.advanceClock(by: .seconds(1))
    _ = session.withLock { $0.recordCancellationRequest(for: admission.invocationID) }
    let beforeCompletion = session.checkpoint()
    try session.advanceClock(by: .nanoseconds(2))
    _ = session.withLock { $0.complete(admission.invocationID, phase: .returned, origin: .forwarded) }

    let trace = try decoded(session.snapshot(), maximumRecords: 2)
    #expect(trace.records.map(\.kind) == ["cancellationRequested", "returned"])
    #expect(trace.records.map(\.ordinal) == ["2", "3"])
    #expect(trace.records.map(\.configurationRevision) == ["11", "11"])
    #expect(trace.records.map(\.elapsedSeconds) == ["1", "1"])
    #expect(trace.records.map(\.elapsedAttoseconds) == ["0", "2000000000"])
    #expect(trace.records.map(\.origin) == [nil, "forwarded"])
    #expect(trace.omitted == .init(count: 1, firstOrdinal: "1", lastOrdinal: "1"))
    try session.discardEvents(through: beforeCompletion)
    let pruned = try decoded(session.snapshot())
    #expect(pruned.records.map(\.ordinal) == ["3"])
    #expect(pruned.prunedThrough == "1")
    #expect(pruned.cancellationRequestsPrunedThrough == "2")
    #expect(pruned.omitted == nil)
}

private final class TraceDescriptionProbe: Sendable, CustomStringConvertible {
    let value = "private payload sentinel"
    private let descriptionCount = CriticalState(0)

    var description: String {
        descriptionCount.withLock { $0 += 1 }
        return value
    }

    var evaluations: Int { descriptionCount.withLock { $0 } }
}

@Test func DX027_traceBoundsEscapedEndpointTextWithoutVisitingPayloads() throws {
    let session = MockSession(clock: .manual)
    let payload = TraceDescriptionProbe()
    let setup = SyncStubbing<TraceDescriptionProbe, String>()
    setup.matching(.any).willReturn("private result sentinel")
    let escapedPrefix = String(repeating: "\u{0001}", count: 95)
    let endpoint = SyncEndpoint(
        id: EndpointID(escapedPrefix + "🧪" + String(repeating: "private label suffix", count: 1_000),
                       specializedFor: TraceDescriptionProbe.self),
        configuration: setup.finish(), failureReporter: FailureReporter { _ in },
        scope: session.makeMock()
    )
    for _ in 0..<128 { _ = endpoint.invoke(payload) }

    let snapshot = try session.finishIfQuiescent()
    let bytes = try snapshot.exportTraceJSON(maximumRecords: 256)
    let trace = try JSONDecoder().decode(ExportedTrace.self, from: bytes)
    let string = String(decoding: bytes, as: UTF8.self)
    #expect(bytes.count <= 263_168)
    #expect(trace.isFinished)
    #expect(trace.records.count == 256)
    #expect(trace.records.allSatisfy {
        $0.endpointTruncated && $0.endpoint == escapedPrefix && $0.specialized
    })
    #expect(!string.contains("private payload sentinel"))
    #expect(!string.contains("private result sentinel"))
    #expect(!string.contains("private label suffix"))
    #expect(!string.contains("TraceDescriptionProbe"))
    #expect(!string.contains("unknown context at"))
    #expect(!string.contains("\u{FFFD}"))
    #expect(payload.evaluations == 0)
}
