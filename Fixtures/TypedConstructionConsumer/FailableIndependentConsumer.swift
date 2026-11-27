import BlueprintMocking
import FailableConstructorDomain
import Foundation

private let reporter = FailureReporter { issue in
    let line = "Failable constructor issue: \(issue.message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

@main struct FailableIndependentConsumer {
    static func main() async throws {
        let session = MockSession()
        let scope = FailableConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: session
        ) { seed, stubs in
            let during = session.snapshot()
            precondition(during.activeInvocationCount == 1)
            precondition(during.events.last?.phase == .admitted)
            precondition(during.events.last?.constructedMockID == nil)
            if seed < 0 {
                stubs.label(.any).willReturn("discarded")
                return .returnNil
            }
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
            return .initialize
        }
        switch CommandLine.arguments.dropFirst().first {
        case "unscoped":
            _ = createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 1)
            return
        case "unbound-detached":
            _ = await scope.withValue {
                await Task.detached { createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 1) }.value
            }
            return
        case "stale":
            _ = try session.resetHistory()
            _ = scope.withValue { createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 1) }
            return
        case "finished":
            _ = try session.finishIfQuiescent()
            _ = scope.withValue { createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 1) }
            return
        default: break
        }

        let beforeNil = session.makeMock().id
        let declined = scope.withValue { createFailableDirectory(FailableConstructionDirectoryMock.self, seed: -11) }
        precondition(declined == nil)
        let firstAttempt = session.snapshot().events
        precondition(firstAttempt.map(\.phase) == [.admitted, .returned])
        precondition(firstAttempt[0].invocationID == firstAttempt[1].invocationID)
        precondition(firstAttempt[0].mockID == firstAttempt[1].mockID)
        precondition(firstAttempt.allSatisfy { $0.constructedMockID == nil })
        let afterNil = session.makeMock().id
        precondition(afterNil.rawValue == beforeNil.rawValue + 1)

        let accepted = await Task.detached {
            await scope.withValue {
                await Task.yield()
                return createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 21)
            }
        }.value
        guard let accepted else { preconditionFailure("A successful plan returned nil") }
        precondition(accepted.label(3) == "21/3")
        precondition(accepted.verify.label(.equal(3), phase: .returned).wasCalled(.once).passed)
        let finished = try session.finishIfQuiescent()
        let events = finished.events
        precondition(events.map(\.phase) == [.admitted, .returned, .admitted, .returned, .admitted, .returned])
        precondition(events[2].invocationID == events[3].invocationID)
        precondition(events[0...3].allSatisfy { $0.mockID == firstAttempt[0].mockID })
        precondition(events[3].constructedMockID == events[4].mockID)
        precondition(events[3].constructedMockID != events[3].mockID)
        precondition(events[3].endpoint.rawValue.contains("init?(seed:Swift.Int)->Self?"))

        let trace = try JSONSerialization.jsonObject(with: finished.exportTraceJSON()) as! [String: Any]
        let records = trace["records"] as! [[String: Any]]
        precondition(records[1]["kind"] as? String == "returned")
        precondition(records[1]["constructedMockID"] == nil)
        precondition(records[3]["constructedMockID"] as? String == String(events[4].mockID.rawValue))

        let archivedSession = MockSession()
        let previous = archivedSession.snapshot().epoch
        let archival = FailableConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: archivedSession
        ) { _, _ in
            precondition(archivedSession.snapshot().activeInvocationCount == 1)
            do { _ = try archivedSession.resetHistory(.detachActive) }
            catch { preconditionFailure("Detach-active reset failed: \(error)") }
            return .returnNil
        }
        let delayedNil = archival.withValue { createFailableDirectory(FailableConstructionDirectoryMock.self, seed: 2) }
        precondition(delayedNil == nil)
        let old = archivedSession.snapshot(epoch: previous)!
        precondition(old.events.map(\.phase) == [.admitted, .returned])
        precondition(old.events.allSatisfy { $0.constructedMockID == nil })
        precondition(archivedSession.snapshot().events.isEmpty)
        print("PASS: GEN026 failable construction returns configured nil and links only successful instances")
    }
}
