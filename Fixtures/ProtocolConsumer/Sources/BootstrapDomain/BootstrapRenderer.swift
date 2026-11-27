@Swift.MainActor
open class BootstrapRenderer {
    public private(set) var bootstrapValue: Swift.String = ""

    public init(seed: Swift.String) {
        bootstrapValue = render(seed)
    }

    open func render(_ value: Swift.String) -> Swift.String {
        "real:\(value)"
    }

    public final func envelope(_ value: Swift.String) -> Swift.String {
        "outer:\(render(value))"
    }
}
