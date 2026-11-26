import BlueprintMocking
func invalid() {
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { value async in value }
}
