public enum OtherSwift {
    public typealias Int = Swift.Bool
}

public typealias AliasForIntCursor = IntCursor

extension AliasForIntCursor {
    public typealias Swift = OtherSwift
}
