import BlueprintMocking
import ConsumerDomain

func invalid() {
    _ = SyncStubbing<DirectoryEntry, DirectoryEntry>()
}
