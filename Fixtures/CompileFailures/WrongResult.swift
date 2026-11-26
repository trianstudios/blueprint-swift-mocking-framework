import BlueprintMocking
func invalid() {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willReturn(123)
}
