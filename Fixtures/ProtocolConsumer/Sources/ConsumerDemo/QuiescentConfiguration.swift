import BlueprintMocking

private enum FixtureFailure: Error { case unexpectedCall }

private final class RetiredPlanCapture: Sendable {
    let onRetire: @Sendable () -> Void

    init(onRetire: @escaping @Sendable () -> Void) {
        self.onRetire = onRetire
    }

    deinit { onRetire() }
}

private func monitoredPlan(
    onRetire: @escaping @Sendable () -> Void
) -> AsyncThrowingConfiguration<Int, Int, FixtureFailure> {
    let capture = RetiredPlanCapture(onRetire: onRetire)
    let stubs = AsyncThrowingStubbing<Int, Int, FixtureFailure>()
    stubs.matching(.any).willAnswer { _ in withExtendedLifetime(capture) { 1 } }
    return stubs.finish()
}

private func returning(_ value: Int) -> AsyncThrowingConfiguration<Int, Int, FixtureFailure> {
    let stubs = AsyncThrowingStubbing<Int, Int, FixtureFailure>()
    stubs.matching(.any).willReturn(value)
    return stubs.finish()
}

func verifyQuiescentConfiguration(reporter: FailureReporter) async throws {
    let session = MockSession()
    let endpoint = AsyncThrowingEndpoint(
        id: EndpointID("quiescent-replacement"), configuration: returning(0),
        failureReporter: reporter, scope: session.makeMock(), failureMapping: { _ in .unexpectedCall }
    )
    let nestedPlan = returning(3)
    let initial = endpoint.replaceConfiguration(monitoredPlan { [weak endpoint] in
        guard let endpoint else { return }
        precondition(session.snapshot().activeInvocationCount == 0)
        precondition(endpoint.invocations.isEmpty)
        do {
            let revision = try endpoint.replaceConfigurationIfQuiescent(nestedPlan)
            precondition(revision.rawValue == 3)
        } catch {
            preconditionFailure("Retired configuration could not reenter: \(error)")
        }
    })
    precondition(initial.rawValue == 1)

    let replacement = try endpoint.replaceConfigurationIfQuiescent(returning(2))
    let answer = try await endpoint.invoke(5)
    precondition(replacement.rawValue == 2 && answer == 3)
    precondition(endpoint.invocations.map(\.configurationRevision.rawValue) == [3])
    print("PASS: RUN035 retired configuration reentered both locks and published the next revision")
}
