import BlueprintMocking
import Foundation
import TypedConstructorDomain

private let reporter = FailureReporter { issue in
    let line = "Typed constructor issue: \(issue.message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

@main struct IndependentConsumer {
    static func main() throws {
        let session = MockSession()
        let scope = TypedConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: session
        ) { seed, stubs throws(ConstructionFailure) in
            let during = session.snapshot()
            precondition(during.activeInvocationCount == 1)
            precondition(during.events.last?.phase == .admitted)
            precondition(during.events.last?.constructedMockID == nil)
            if seed < 0 {
                // Populating a local rule before throwing must not attach an endpoint or instance.
                stubs.label(.any).willReturn("discard this")
                throw .rejected(seed: seed)
            }
            stubs.label(.any).willAnswer { "\(seed)/\($0)" }
        }
        switch CommandLine.arguments.dropFirst().first {
        case "unscoped":
            _ = try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 1)
            return
        case "stale":
            _ = try session.resetHistory()
            _ = try scope.withValue { try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 1) }
            return
        case "finished":
            _ = try session.finishIfQuiescent()
            _ = try scope.withValue { try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 1) }
            return
        default: break
        }

        let beforeFailure = session.makeMock().id
        let failure: ConstructionFailure = scope.withValue {
            do throws(ConstructionFailure) {
                _ = try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: -19)
                preconditionFailure("A failed constructor created a mock")
            } catch {
                return error
            }
        }
        precondition(failure == .rejected(seed: -19))
        let failed = session.snapshot().events
        precondition(failed.map(\.phase) == [.admitted, .threw])
        precondition(failed[0].invocationID == failed[1].invocationID)
        precondition(failed[0].mockID == failed[1].mockID)
        precondition(failed.allSatisfy { $0.constructedMockID == nil })
        let afterFailure = session.makeMock().id
        precondition(afterFailure.rawValue == beforeFailure.rawValue + 1)

        let first = try scope.withValue { try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 7) }
        let second = try scope.withValue { try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 9) }
        precondition(first !== second)
        precondition(first.label(3) == "7/3")
        precondition(second.label(4) == "9/4")
        precondition(first.verify.label(.equal(3), phase: .returned).wasCalled(.once).passed)
        let events = session.snapshot().events
        precondition(events.map(\.phase) == [.admitted, .threw, .admitted, .returned, .admitted, .returned,
                                           .admitted, .returned, .admitted, .returned])
        precondition(events[2].invocationID == events[3].invocationID)
        precondition(events[4].invocationID == events[5].invocationID)
        precondition(events[0...5].allSatisfy { $0.mockID == failed[0].mockID })
        precondition(events[3].constructedMockID == events[6].mockID)
        precondition(events[5].constructedMockID == events[8].mockID)
        precondition(events[3].constructedMockID != events[5].constructedMockID)
        precondition(events[3].constructedMockID != failed[0].mockID)
        precondition(events[3].endpoint.rawValue.contains("throws(TypedConstructorDomain.ConstructionFailure)"))
        precondition(session.snapshot().activeInvocationCount == 0)
        let traceData = try session.snapshot().exportTraceJSON()
        let trace = try JSONSerialization.jsonObject(with: traceData) as! [String: Any]
        let records = trace["records"] as! [[String: Any]]
        precondition(records[1]["constructedMockID"] == nil)
        precondition(records[3]["constructedMockID"] as? String == String(events[6].mockID.rawValue))
        precondition(records[5]["constructedMockID"] as? String == String(events[8].mockID.rawValue))

        let archivedSession = MockSession()
        let oldEpoch = archivedSession.snapshot().epoch
        let archival = TypedConstructionDirectoryMock.makeConstructionScope(
            failureReporter: reporter, session: archivedSession
        ) { seed, _ throws(ConstructionFailure) in
            precondition(archivedSession.snapshot().activeInvocationCount == 1)
            do { _ = try archivedSession.resetHistory(.detachActive) }
            catch { preconditionFailure("Detach-active reset failed: \(error)") }
            throw .rejected(seed: seed)
        }
        archival.withValue {
            do throws(ConstructionFailure) {
                _ = try createTypedDirectory(TypedConstructionDirectoryMock.self, seed: 31)
                preconditionFailure("Expected a typed error after detaching")
            } catch {
                precondition(error == .rejected(seed: 31))
            }
        }
        let archivedFailure = archivedSession.snapshot(epoch: oldEpoch)!
        precondition(archivedFailure.events.map(\.phase) == [.admitted, .threw])
        precondition(archivedFailure.events.allSatisfy { $0.constructedMockID == nil })
        precondition(archivedSession.snapshot().events.isEmpty)
        print("PASS: GEN026 typed construction records exact failure and attaches only successful instances")
    }
}
