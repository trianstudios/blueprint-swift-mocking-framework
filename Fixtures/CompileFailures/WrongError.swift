import BlueprintMocking
enum Expected: Error { case offline }
enum Other: Error { case invalid }
func invalid() {
    let stubs = AsyncThrowingStubbing<String, String, Expected>()
    stubs.matching(.any).willThrow(Other.invalid)
}
