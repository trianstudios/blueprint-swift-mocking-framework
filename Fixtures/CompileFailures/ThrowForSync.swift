import BlueprintMocking
enum SomeError: Error { case wrong }
func invalid() {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willThrow(SomeError.wrong)
}
