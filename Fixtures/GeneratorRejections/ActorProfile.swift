@globalActor
public actor WorkActor {
    public static let shared = WorkActor()
}

@WorkActor
public protocol ActorProfile {
    func load(id: String) -> String
}
