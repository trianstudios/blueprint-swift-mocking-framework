import ConsumerDoubles

nonisolated func invalidDetachedCallback(_ stubs: CallbackSpyDirectoryMock.Stubs) {
    stubs.transform(id: .any).willAnswer { _, callback in
        Task.detached { _ = callback(1) }
        return "not scoped"
    }
}
