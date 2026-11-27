import ConsumerDomain

nonisolated func eraseAnswer(
    _ answer: @escaping @Sendable (isolated IsolatedDirectoryWorker) -> Int
) -> @Sendable (IsolatedDirectoryWorker) -> Int {
    answer
}
