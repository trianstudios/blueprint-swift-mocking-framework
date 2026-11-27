import Foundation

public enum SessionTraceExportError: Error, Equatable, Sendable {
    case invalidRecordLimit
    case encodingFailed
}

public extension SessionSnapshot {
    /// Exports a version 1 JSON trace of this captured epoch's retained metadata.
    ///
    /// The limit is 0 through 256 records. The newest retained calls and cancellation
    /// requests share the limit and appear in ascending session order. Pruning before
    /// capture and omissions during export are identified separately.
    ///
    /// Developer-supplied endpoint labels are emitted with a 96-byte UTF-8 prefix.
    /// Specializations are marked without runtime type text or identities. The export
    /// includes no argument or result values or projections. The maximum encoded size
    /// is 1,024 bytes plus 1,024 bytes per exported record, up to 263,168 bytes.
    func exportTraceJSON(maximumRecords: Int = 128) throws(SessionTraceExportError) -> Data {
        guard (0...256).contains(maximumRecords) else { throw .invalidRecordLimit }
        let trace = SessionTraceDocument(snapshot: self, maximumRecords: maximumRecords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(trace)
        } catch {
            throw .encodingFailed
        }
        // There is one bounded text field per row. Even if every input byte
        // becomes a six-byte JSON escape, 1 KiB covers the whole row and comma.
        guard encoded.count <= 1_024 + 1_024 * trace.records.count else { throw .encodingFailed }
        return encoded
    }
}

private struct SessionTraceDocument: Encodable {
    struct Omission: Encodable {
        let count: Int
        let firstOrdinal: String
        let lastOrdinal: String
    }

    let schemaVersion = 1
    let sessionID: String
    let epoch: String
    let watermark: String
    let activeInvocationCount: Int
    let isFinished: Bool
    let payloads = "omitted"
    let prunedThrough: String?
    let cancellationRequestsPrunedThrough: String?
    let omitted: Omission?
    let records: [SessionTraceRecord]

    init(snapshot: SessionSnapshot, maximumRecords: Int) {
        sessionID = snapshot.sessionID.rawValue.uuidString
        epoch = String(snapshot.epoch.rawValue)
        watermark = String(snapshot.watermark)
        activeInvocationCount = snapshot.activeInvocationCount
        isFinished = snapshot.isFinished
        prunedThrough = snapshot.prunedThrough.map { String($0) }
        cancellationRequestsPrunedThrough = snapshot.cancellationRequestsPrunedThrough.map { String($0) }

        var events = snapshot.events[...]
        var cancellations = snapshot.cancellationRequests[...]
        var newestFirst: [SessionTraceRecord] = []
        newestFirst.reserveCapacity(min(maximumRecords, events.count + cancellations.count))
        // Select a bounded suffix without sorting or copying the whole retained history.
        while newestFirst.count < maximumRecords {
            if let request = cancellations.last, request.ordinal > (events.last?.ordinal ?? 0) {
                newestFirst.append(SessionTraceRecord(cancellation: request))
                cancellations.removeLast()
            } else if let event = events.popLast() {
                newestFirst.append(SessionTraceRecord(event: event))
            } else {
                break
            }
        }
        records = Array(newestFirst.reversed())

        let omittedCount = events.count + cancellations.count
        if omittedCount == 0 {
            omitted = nil
        } else {
            let first = min(events.first?.ordinal ?? UInt64.max, cancellations.first?.ordinal ?? UInt64.max)
            let last = max(events.last?.ordinal ?? 0, cancellations.last?.ordinal ?? 0)
            omitted = Omission(count: omittedCount, firstOrdinal: String(first), lastOrdinal: String(last))
        }
    }
}

private struct SessionTraceRecord: Encodable {
    private enum Kind: String, Encodable {
        case admitted
        case returned
        case threw
        case terminated
        case cancellationRequested

        init(_ phase: CallPhase) {
            switch phase {
            case .admitted: self = .admitted
            case .returned: self = .returned
            case .threw: self = .threw
            case .terminated: self = .terminated
            }
        }
    }

    let ordinal: String
    let elapsedSeconds: String
    let elapsedAttoseconds: String
    let mockID: String
    let invocationID: String
    let configurationRevision: String
    private let kind: Kind
    let origin: String?
    let endpoint: String
    let endpointTruncated: Bool
    let specialized: Bool

    init(event: SessionEvent) {
        self.init(admissionOrOutcome: event, ordinal: event.ordinal, elapsed: event.elapsed, kind: Kind(event.phase))
    }

    init(cancellation: SessionCancellationRequest) {
        self.init(admissionOrOutcome: cancellation.admission, ordinal: cancellation.ordinal,
                  elapsed: cancellation.elapsed, kind: .cancellationRequested)
    }

    private init(admissionOrOutcome event: SessionEvent, ordinal: UInt64, elapsed: Duration, kind: Kind) {
        self.ordinal = String(ordinal)
        let duration = elapsed.components
        elapsedSeconds = String(duration.seconds)
        elapsedAttoseconds = String(duration.attoseconds)
        mockID = String(event.mockID.rawValue)
        invocationID = String(event.invocationID.rawValue)
        configurationRevision = String(event.configurationRevision.rawValue)
        self.kind = kind
        origin = event.origin == .forwarded ? "forwarded" : nil
        (endpoint, endpointTruncated) = Self.endpointPrefix(event.endpoint.rawValue)
        specialized = event.endpoint.specialization != nil
    }

    private static func endpointPrefix(_ label: String) -> (String, Bool) {
        let limit = 96
        let bytes = Array(label.utf8.prefix(limit + 1))
        guard bytes.count > limit else { return (label, false) }
        var end = limit
        while bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return (String(decoding: bytes.prefix(end), as: UTF8.self), true)
    }
}
