import ConsumerDoubles

func selectWrongScopedFetch(_ mock: ScopedUserDirectoryMock) async throws {
    try await mock.ruleScopes.fetch(id: Int.self, configure: { _ in }, operation: {})
}
