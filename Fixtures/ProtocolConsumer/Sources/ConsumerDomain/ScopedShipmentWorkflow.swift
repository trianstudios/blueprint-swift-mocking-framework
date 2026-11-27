public struct ShipmentPolicy: Equatable, Sendable {
    public let carrier: String

    public init(carrier: String) {
        self.carrier = carrier
    }
}

public final class FactoryShipment: Sendable {
    public let id: String
    public let policy: ShipmentPolicy

    public init(id: String, policy: ShipmentPolicy) {
        self.id = id
        self.policy = policy
    }
}

public protocol ScopedShipmentFactory: Sendable {
    static subscript(configuration region: String) -> ShipmentPolicy { get }
    static subscript(construct id: String, using policy: ShipmentPolicy) -> FactoryShipment { get }
}

public protocol ShipmentFactoryAudit: Sendable {
    func dispatched(_ shipment: FactoryShipment)
}

public struct ScopedShipmentWorkflow<Factory: ScopedShipmentFactory>: Sendable {
    private let factory: Factory.Type
    private let audit: any ShipmentFactoryAudit

    public init(factory: Factory.Type, audit: any ShipmentFactoryAudit) {
        self.factory = factory
        self.audit = audit
    }

    public func dispatch(id: String, region: String) -> FactoryShipment {
        let policy = factory[configuration: region]
        let shipment = factory[construct: id, using: policy]
        audit.dispatched(shipment)
        return shipment
    }
}
