public protocol TypeSubscriptDirectory: Sendable {
    static subscript(_ key: Int) -> Int { get set }
    subscript(_ key: Int) -> Int { get set }
}

public enum TypeSubscriptClient {
    public static func read<Directory: TypeSubscriptDirectory>(_ key: Int, using type: Directory.Type) -> Int {
        type[key]
    }

    public static func increment<Directory: TypeSubscriptDirectory>(
        _ key: Int, by amount: Int, using type: Directory.Type
    ) {
        type[key] += amount
    }
}
