public struct DefaultCatalogProduct: Sendable, Equatable {
    public let name: String

    public init(name: String) { self.name = name }
}

public struct DefaultCatalogRegion: Sendable {
    public let name: String

    public init(name: String) { self.name = name }
}

public protocol DefaultCatalogDirectory: Sendable {
    func lookup(sku: String) -> DefaultCatalogProduct
}

public struct DefaultCatalogReader: Sendable {
    private let directory: any DefaultCatalogDirectory

    public init(directory: any DefaultCatalogDirectory) { self.directory = directory }

    public func product(for sku: String) -> DefaultCatalogProduct {
        directory.lookup(sku: sku)
    }
}
