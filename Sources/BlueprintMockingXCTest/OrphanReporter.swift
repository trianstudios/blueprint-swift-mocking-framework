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
            let issue = failure.issue
            let source = issue.source
            let location = source.line > 0 && !source.filePath.isEmpty
                ? XCTSourceCodeLocation(filePath: source.filePath, lineNumber: source.line) : nil
            let owner = "session=\(failure.epoch.sessionID.rawValue.uuidString) epoch=\(failure.epoch.rawValue)"
                + " mock=\(failure.mockID.rawValue) ordinal=\(failure.ordinal)"
            let details = "\(owner) source=\(source.fileID) line=\(source.line) column=\(source.column)"
            suiteRun.record(XCTIssue(
                type: .assertionFailure, compactDescription: issue.message,
                detailedDescription: details, sourceCodeContext: XCTSourceCodeContext(location: location),
                associatedError: nil, attachments: []
            ))
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
