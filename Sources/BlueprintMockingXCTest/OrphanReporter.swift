#if os(macOS)
import BlueprintMocking
import XCTest

public enum XCTestOrphanFlushError: Error, Equatable, Sendable {
    case inactiveSuite
}

extension FailureReporter {
    /// Records buffered post-close failures on an active XCTest suite run.
    ///
    /// Invoke on the suite's runner path while the suite is active. Join known
    /// producers before a final flush. An inactive suite leaves the buffer intact.
    @discardableResult
    public static func flushXCTestOrphans(
        _ buffer: OrphanFailureBuffer, in suiteRun: XCTestSuiteRun
    ) throws(XCTestOrphanFlushError) -> OrphanFailureBatch {
        guard suiteRun.startDate != nil && suiteRun.stopDate == nil else { throw .inactiveSuite }

        let batch = buffer.drain()
        for failure in batch.failures {
            let owner = "session=\(failure.epoch.sessionID.rawValue.uuidString) epoch=\(failure.epoch.rawValue)"
                + " mock=\(failure.mockID.rawValue) ordinal=\(failure.ordinal) "
            suiteRun.record(nativeXCTestIssue(failure.issue, detailPrefix: owner))
        }
        if batch.droppedCount > 0 {
            suiteRun.record(XCTIssue(
                type: .assertionFailure,
                compactDescription: "Blueprint Mocking lost orphan failure records (\(batch.droppedCount) dropped)"
            ))
        }
        return batch
    }
}
#endif
