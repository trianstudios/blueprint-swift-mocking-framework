import BlueprintMocking
final class MutableBox { var value = "unsafe" }
func invalid() {
    let box = MutableBox()
    let stubs = SyncStubbing<String, String>()
    stubs.matching(.any).willAnswer { _ in box.value }
}
