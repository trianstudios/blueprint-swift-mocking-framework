import Foundation
import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

@main struct Demo {
    static func main() async throws {
        let reporter = FailureReporter { issue in
            FileHandle.standardError.write(Data("MOCK ISSUE: \(issue.message)\n".utf8))
        }
        if CommandLine.arguments.contains("--missing-never") {
            let mock = EffectEdgesMock(failureReporter: reporter) { _ in }
            mock.stop(id: "unstubbed")
        }
        let mock = UserRepositoryMock(failureReporter: reporter) { stubs in
            stubs.fetchUser(id: .equal("42")).willReturn("Ada")
            stubs.greeting(for: .any).willAnswer { "Hello, " + $0 }
        }
        if CommandLine.arguments.contains("--missing-sync") {
            _ = mock.greeting("unstubbed")
            return
        }
        if CommandLine.arguments.contains("--missing") {
            _ = try await mock.fetchUser(id: "unstubbed")
            return
        }
        let service = UserService(repository: mock)
        let value = try await service.load(id: "42")
        precondition(value == "Ada")
        precondition(mock.greeting(for: value) == "Hello, Ada")
        precondition(mock.verify.fetchUser(id: .equal("42")).wasCalled(.once).passed)
        precondition(mock.verify.greeting(for: .equal("Ada")).wasCalled(.once).passed)
        print("PASS: generated protocol → typed stubs → service → exact verification")
    }
}
