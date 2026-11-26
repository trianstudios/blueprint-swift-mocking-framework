import Foundation

/// A failure from a closed session, with its original mock and epoch.
public struct OrphanFailure: Sendable {
    /// A monotonically increasing identity within the buffer.
    public let ordinal: UInt64
    public let epoch: SessionEpoch
    public let mockID: MockID
    public let issue: MockIssue
}

/// A claimed batch. Dropped failures still count against the run.
public struct OrphanFailureBatch: Sendable {
    public let failures: [OrphanFailure]
    public let droppedCount: Int
}

/// An explicitly shared, bounded mailbox for post-close issues.
public final class OrphanFailureBuffer: Sendable {
    private struct State: Sendable {
        var nextOrdinal: UInt64 = 0
        var failures: [OrphanFailure] = []
        var droppedCount = 0
    }

    private let capacity: Int
    private let maximumIssueBytes: Int
    private let state = CriticalState(State())

    /// Retains the earliest pending failures up to capacity. The byte limit applies to
    /// each issue's endpoint names, message and source strings combined.
    public init(capacity: Int = 256, maximumIssueBytes: Int = 16_384) {
        precondition(capacity > 0 && maximumIssueBytes > 0)
        self.capacity = capacity
        self.maximumIssueBytes = maximumIssueBytes
    }

    /// Atomically removes the current records and dropped count. Join known producers
    /// before the last drain. A concurrent producer may add records for the next batch.
    public func drain() -> OrphanFailureBatch {
        state.withLock {
            let batch = OrphanFailureBatch(failures: $0.failures, droppedCount: $0.droppedCount)
            $0.failures = []
            $0.droppedCount = 0
            return batch
        }
    }

    func record(_ issue: MockIssue, mockID: MockID, epoch: SessionEpoch) {
        let bytes = issue.endpoint.rawValue.utf8.count
            + (issue.endpoint.specialization?.typeName.utf8.count ?? 0)
            + issue.message.utf8.count + issue.source.fileID.utf8.count + issue.source.filePath.utf8.count
        state.withLock {
            $0.nextOrdinal += 1
            guard $0.failures.count < capacity, bytes <= maximumIssueBytes else {
                $0.droppedCount += 1
                return
            }
            $0.failures.append(.init(ordinal: $0.nextOrdinal, epoch: epoch, mockID: mockID, issue: issue))
        }
    }
}

extension MockScope {
    func bufferOrphan(_ issue: MockIssue, closedEpoch: SessionEpoch?, terminating: Bool) -> Bool {
        guard let closedEpoch, let buffer = session.orphanFailures else { return false }
        let owner = expectedEpoch ?? closedEpoch
        buffer.record(issue, mockID: id, epoch: owner)
        if terminating {
            // The trap ends the process before an in-memory buffer can be drained.
            let detail = "\(issue.source.filePath):\(issue.source.line):\(issue.source.column): \(issue.message)"
            let singleLine = String(decoding: detail.utf8.prefix(1_024), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let diagnostic = "MOCK ORPHAN: session \(id.sessionID.rawValue) epoch \(owner.rawValue) \(singleLine)\n"
            try? FileHandle.standardError.write(contentsOf: Data(diagnostic.utf8))
        }
        return true
    }
}
