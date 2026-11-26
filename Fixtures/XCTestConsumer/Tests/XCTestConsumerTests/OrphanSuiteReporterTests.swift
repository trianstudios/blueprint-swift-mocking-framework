#if os(macOS)
import Dispatch
import Foundation
import XCTest
import BlueprintMocking
import BlueprintMockingXCTest

private final class OrphanSuiteProbe: NSObject, XCTestObservation, @unchecked Sendable {
    struct ObservedIssue {
        let name: String
        let file: String?
        let line: Int?
        let details: String?
    }

    let buffer: OrphanFailureBuffer
    let owner: MockSession
    let releaseGate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let returned = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var ownerSnapshot: SessionSnapshot?
    private var ownerCompleted = false
    private var suiteRun: XCTestSuiteRun?
    private var issues: [ObservedIssue] = []

    override init() {
        let buffer = OrphanFailureBuffer(capacity: 1)
        self.buffer = buffer
        self.owner = MockSession(orphanFailures: buffer)
        super.init()
    }

    var finalOwnerSnapshot: SessionSnapshot? { lock.withLock { ownerSnapshot } }
    var ownerDidFinish: Bool { lock.withLock { ownerCompleted } }
    var activeSuiteRun: XCTestSuiteRun? { lock.withLock { suiteRun } }
    var suiteIssues: [ObservedIssue] { lock.withLock { issues } }

    func save(_ snapshot: SessionSnapshot) {
        lock.withLock { ownerSnapshot = snapshot }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard testCase.name.contains("OrphanSuiteReporterTests") else { return }
        if testCase.name.contains("testAOwnerSchedulesOrphan") {
            lock.withLock { ownerCompleted = true }
        }
        print("BLUEPRINT XCTEST CASE FINISHED \(testCase.name) failures=\(testCase.testRun?.totalFailureCount ?? -1)")
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        guard testCase.name.contains("OrphanSuiteReporterTests") else { return }
        print("BLUEPRINT XCTEST CASE STARTED \(testCase.name)")
    }

    func testSuiteWillStart(_ testSuite: XCTestSuite) {
        guard testSuite.name == "OrphanSuiteReporterTests" else { return }
        lock.withLock { suiteRun = testSuite.testRun as? XCTestSuiteRun }
    }

    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        guard testSuite.name == "OrphanSuiteReporterTests" else { return }
        print("BLUEPRINT XCTEST SUITE FINISHED \(testSuite.name) failures=\(testSuite.testRun?.totalFailureCount ?? -1)")
        lock.withLock { suiteRun = nil }
    }

    func testSuite(_ testSuite: XCTestSuite, didRecord issue: XCTIssue) {
        guard testSuite.name == "OrphanSuiteReporterTests" else { return }
        let location = issue.sourceCodeContext.location
        lock.withLock {
            issues.append(ObservedIssue(name: issue.compactDescription,
                                        file: location?.fileURL.lastPathComponent,
                                        line: location?.lineNumber, details: issue.detailedDescription))
        }
        print("BLUEPRINT XCTEST SUITE ISSUE \(testSuite.name) \(issue.compactDescription)")
    }
}

final class OrphanSuiteReporterTests: XCTestCase {
    private static let probe = OrphanSuiteProbe()
    private static let mode = ProcessInfo.processInfo.environment["BLUEPRINT_XCTEST_ORPHAN_MODE"]
    private static let installObservation: Void = {
        XCTestObservationCenter.shared.addTestObserver(probe)
    }()

    override class var defaultTestSuite: XCTestSuite {
        if mode != nil { _ = installObservation }
        return super.defaultTestSuite
    }

    @objc func testAOwnerSchedulesOrphan() throws {
        try XCTSkipUnless(Self.mode != nil)
        let mode = try XCTUnwrap(Self.mode)
        let probe = Self.probe
        let owner = probe.owner
        let scope = LookupMock.makeTypeScope(failureReporter: .xctest, session: owner) { stubs in
            stubs.set_subscript(.any, newValue: .any).willReturn(())
        }
        scope.withValue {
            LookupMock[7] = 1
            Task {
                var gate = probe.releaseGate.stream.makeAsyncIterator()
                guard await gate.next() != nil else { return }
                LookupMock[7] = 2
                if mode == "overflow" { LookupMock[7] = 4 }
                probe.returned.signal()
            }
        }
        probe.save(try owner.finishIfQuiescent())
    }

    @objc func testBPeerFlushesIntoTheSuite() throws {
        try XCTSkipUnless(Self.mode != nil)
        let mode = try XCTUnwrap(Self.mode)
        let probe = Self.probe
        let finalA = try XCTUnwrap(probe.finalOwnerSnapshot)
        let ownerEvent = try XCTUnwrap(finalA.events.first)
        let suiteRun = try XCTUnwrap(probe.activeSuiteRun)
        XCTAssertTrue(probe.ownerDidFinish)
        let peer = MockSession(orphanFailures: probe.buffer)
        let peerScope = LookupMock.makeTypeScope(failureReporter: .xctest, session: peer) { stubs in
            stubs.set_subscript(.any, newValue: .any).willReturn(())
        }

        try peerScope.withValue {
            LookupMock[7] = 3
            let before = peer.snapshot()
            probe.releaseGate.continuation.yield(())
            probe.releaseGate.continuation.finish()
            XCTAssertEqual(probe.returned.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(peer.snapshot(), before)
            XCTAssertEqual(probe.owner.snapshot(), finalA)
            XCTAssertEqual(suiteRun.totalFailureCount, 0)

            let batch: OrphanFailureBatch
            if mode == "wrong-owner" {
                batch = probe.buffer.drain()
                for failure in batch.failures { FailureReporter.xctest.report(failure.issue) }
            } else {
                let inactiveRun = XCTestSuiteRun(test: XCTestSuite(name: "Inactive probe"))
                XCTAssertThrowsError(try FailureReporter.flushXCTestOrphans(probe.buffer, in: inactiveRun)) {
                    XCTAssertEqual($0 as? XCTestOrphanFlushError, .inactiveSuite)
                }
                inactiveRun.start()
                inactiveRun.stop()
                XCTAssertNotNil(inactiveRun.startDate)
                XCTAssertNotNil(inactiveRun.stopDate)
                XCTAssertThrowsError(try FailureReporter.flushXCTestOrphans(probe.buffer, in: inactiveRun)) {
                    XCTAssertEqual($0 as? XCTestOrphanFlushError, .inactiveSuite)
                }
                batch = try FailureReporter.flushXCTestOrphans(probe.buffer, in: suiteRun)
                XCTAssertEqual(suiteRun.totalFailureCount, mode == "overflow" ? 2 : 1)
                XCTAssertEqual(testRun?.totalFailureCount, 0)
                let second = try FailureReporter.flushXCTestOrphans(probe.buffer, in: suiteRun)
                XCTAssertTrue(second.failures.isEmpty)
                XCTAssertEqual(second.droppedCount, 0)
            }

            XCTAssertEqual(batch.failures.count, 1)
            XCTAssertEqual(batch.droppedCount, mode == "overflow" ? 1 : 0)
            let failure = try XCTUnwrap(batch.failures.first)
            XCTAssertEqual(failure.epoch, finalA.epoch)
            XCTAssertEqual(failure.mockID, ownerEvent.mockID)
            XCTAssertEqual(failure.issue.endpoint, ownerEvent.endpoint)
            XCTAssertEqual(failure.ordinal, 1)
            XCTAssertEqual(failure.issue.kind, .unexpectedCall)
            XCTAssertEqual(failure.issue.source.fileID, "LookupDomain/Lookup.swift")
            XCTAssertEqual(failure.issue.source.filePath, "Lookup.swift")
            XCTAssertTrue(failure.issue.message.hasSuffix(" in a finished mock session"))
            XCTAssertEqual(peer.snapshot(), before)

            if mode != "wrong-owner" {
                let native = try XCTUnwrap(probe.suiteIssues.first)
                XCTAssertEqual(probe.suiteIssues.count, mode == "overflow" ? 2 : 1)
                XCTAssertEqual(native.name, failure.issue.message)
                XCTAssertEqual(native.file, "Lookup.swift")
                XCTAssertEqual(native.line, failure.issue.source.line)
                let details = try XCTUnwrap(native.details)
                XCTAssertTrue(details.contains(failure.epoch.sessionID.rawValue.uuidString))
                XCTAssertTrue(details.contains("epoch=\(failure.epoch.rawValue)"))
                XCTAssertTrue(details.contains("mock=\(failure.mockID.rawValue)"))
                XCTAssertTrue(details.contains("ordinal=\(failure.ordinal)"))
                XCTAssertTrue(details.contains("column=\(failure.issue.source.column)"))
            }
        }
        print("PASS: Blueprint XCTest verified orphan owner, source and one-time batch")
    }
}
#endif
