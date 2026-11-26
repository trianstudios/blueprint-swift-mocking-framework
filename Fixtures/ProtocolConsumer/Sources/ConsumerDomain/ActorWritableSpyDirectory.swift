@MainActor
public protocol ActorWritableSpyDirectory {
    var current: ActorSpyEntry { get nonmutating set }
    subscript(slot key: String) -> ActorSpyEntry { get nonmutating set }
}
