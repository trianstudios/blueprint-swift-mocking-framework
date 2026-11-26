import BlueprintMocking
import Testing

extension FailureReporter {
    public static var swiftTesting: Self {
        Self { issue in
            Issue.record(Comment(rawValue: issue.message), sourceLocation: Testing.SourceLocation(
                fileID: issue.source.fileID, filePath: issue.source.filePath,
                line: issue.source.line, column: issue.source.column))
        }
    }

    /// Reports an orphaned issue to the active Swift Testing run and awaits its delivery.
    ///
    /// The diagnostic text preserves the original location. The native location points
    /// to this adapter so Swift Testing does not infer a test from the original location.
    public static func reportAtSwiftTestingRunLevel(_ issue: MockIssue) async {
        await Task.detached {
            Issue.record(Comment(rawValue: originalDiagnostic(issue)))
        }.value
    }

    /// Claims current orphans and reports them to the active Swift Testing run.
    /// Concurrent flushes claim disjoint batches. Join known producers before the last flush.
    @discardableResult
    public static func flushSwiftTestingOrphans(_ buffer: OrphanFailureBuffer) async -> OrphanFailureBatch {
        let batch = buffer.drain()
        guard !batch.failures.isEmpty || batch.droppedCount > 0 else { return batch }
        await Task.detached {
            for failure in batch.failures {
                let epoch = failure.epoch
                let owner = "Mock session \(epoch.sessionID.rawValue), epoch \(epoch.rawValue), "
                    + "mock \(failure.mockID.rawValue), orphan \(failure.ordinal)"
                Issue.record(Comment(rawValue: "\(owner): \(originalDiagnostic(failure.issue))"))
            }
            if batch.droppedCount > 0 {
                Issue.record(Comment(rawValue: "Blueprint Mocking dropped \(batch.droppedCount) orphan failures"))
            }
        }.value
        return batch
    }

    private static func originalDiagnostic(_ issue: MockIssue) -> String {
        let location = issue.source
        return "\(location.filePath):\(location.line):\(location.column): \(issue.message)"
    }
}
