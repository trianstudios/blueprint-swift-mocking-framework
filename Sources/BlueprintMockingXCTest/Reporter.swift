import BlueprintMocking
import XCTest

extension FailureReporter {
    /// Records each mock failure in the active XCTest context.
    public static var xctest: Self {
        Self { issue in
            let source = issue.source
            if let file = source.staticFilePath, let line = UInt(exactly: source.line), line > 0 {
                XCTFail(issue.message, file: file, line: line)
            } else {
                // XCTFail requires a static file path for native attribution.
                XCTFail("\(source.filePath):\(source.line): \(issue.message)")
            }
        }
    }
}
