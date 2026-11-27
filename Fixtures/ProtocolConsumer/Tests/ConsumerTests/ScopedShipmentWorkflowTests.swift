import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Testing

private struct ShipmentFixture: Sendable {
    let session: MockSession
    let factory: ScopedShipmentFactoryMock.TypeScope
    let audit: ShipmentFactoryAuditMock
    let workflow: ScopedShipmentWorkflow<ScopedShipmentFactoryMock>

    init(policy: ShipmentPolicy) {
        let session = MockSession()
        let factory = ScopedShipmentFactoryMock.makeTypeScope(failureReporter: .swiftTesting, session: session) {
            $0.get_subscript(configuration: .equal("local")).willReturn(policy)
            $0.get_subscript(construct: .equal("42"), using: .equal(policy)).willAnswer { input in
                FactoryShipment(id: input.0, policy: input.1)
            }
        }
        let audit = ShipmentFactoryAuditMock(failureReporter: .swiftTesting, session: session) { stubs in
            stubs.dispatched(.any).willReturn(())
        }
        self.session = session
        self.factory = factory
        self.audit = audit
        self.workflow = ScopedShipmentWorkflow(factory: ScopedShipmentFactoryMock.self, audit: audit)
    }

    func dispatch() -> FactoryShipment {
        workflow.dispatch(id: "42", region: "local")
    }
}

@Test func SYS006_staticFactoryOrdersScopedConstructionBeforeGeneratedAudit() throws {
    let policy = ShipmentPolicy(carrier: "standard")
    let fixture = ShipmentFixture(policy: policy)
    #expect(fixture.session.snapshot().events.isEmpty)
    let shipment = fixture.factory.withValue { fixture.dispatch() }
    #expect(shipment.id == "42")
    #expect(shipment.policy == policy)

    let checks = [
        fixture.factory.verify.get_subscript(configuration: .equal("local"), phase: .returned).wasCalled(.once),
        fixture.factory.verify.get_subscript(construct: .equal("42"), using: .equal(policy), phase: .returned).wasCalled(.once),
        fixture.audit.verify.dispatched(.identical(to: shipment), phase: .returned).wasCalled(.once),
    ]
    for check in checks { #expect(check.passed) }
    let snapshot = fixture.session.snapshot()
    let endpointNames = [
        "|type:subscript:(configuration:String).get->ShipmentPolicy|",
        "|type:subscript:(construct:String,using:ShipmentPolicy).get->FactoryShipment|",
        "|dispatched(_:FactoryShipment)->Void|",
    ]
    let returned = try endpointNames.map { name in
        try #require(snapshot.events.first { $0.endpoint.rawValue.contains(name) && $0.phase == .returned })
    }
    let selectors = returned.map { SessionCallSelector(mockID: $0.mockID, endpoint: $0.endpoint) }
    #expect(returned[0].mockID == returned[1].mockID)
    #expect(returned[1].mockID != returned[2].mockID)
    #expect(snapshot.matchOrder(selectors, mode: .strict, phase: .returned) == .matched(returned))
    #expect(snapshot.matchOrder(Array(selectors.reversed()), mode: .relative, phase: .returned) == .notMatched)
    let acrossMocks = [selectors[0], selectors[2]]
    #expect(snapshot.matchOrder(acrossMocks, mode: .relative, phase: .returned) == .matched([returned[0], returned[2]]))
    #expect(snapshot.matchOrder(acrossMocks, mode: .strict, phase: .returned) == .notMatched)
}

@Test(.timeLimit(.minutes(1)))
func SYS006_parallelStaticFactoryScopesIsolateTheSameMetatype() async {
    let east = ShipmentFixture(policy: ShipmentPolicy(carrier: "east"))
    let west = ShipmentFixture(policy: ShipmentPolicy(carrier: "west"))
    let (eastEntry, eastEntered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (westEntry, westEntered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    let eastTask = Task.detached {
        await east.factory.withValue {
            eastEntered.yield(())
            var peer = westEntry.makeAsyncIterator()
            _ = await peer.next()
            return await Task { east.dispatch() }.value
        }
    }
    let westTask = Task.detached {
        await west.factory.withValue {
            westEntered.yield(())
            var peer = eastEntry.makeAsyncIterator()
            _ = await peer.next()
            return west.dispatch()
        }
    }

    let eastShipment = await eastTask.value
    let westShipment = await westTask.value
    #expect(eastShipment.id == westShipment.id)
    #expect(eastShipment.policy.carrier == "east")
    #expect(westShipment.policy.carrier == "west")
    #expect(eastShipment !== westShipment)
    #expect(east.audit.verify.dispatched(.identical(to: eastShipment)).wasCalled(.once).passed)
    #expect(east.audit.verify.dispatched(.identical(to: westShipment)).wasCalled(.never).passed)
    #expect(west.audit.verify.dispatched(.identical(to: westShipment)).wasCalled(.once).passed)
    #expect(west.audit.verify.dispatched(.identical(to: eastShipment)).wasCalled(.never).passed)
    #expect(east.factory.verify.get_subscript(construct: .any, using: .equal(eastShipment.policy)).wasCalled(.once).passed)
    #expect(west.factory.verify.get_subscript(construct: .any, using: .equal(westShipment.policy)).wasCalled(.once).passed)
    #expect(east.session.snapshot().events.filter { $0.phase == .admitted }.count == 3)
    #expect(west.session.snapshot().events.filter { $0.phase == .admitted }.count == 3)
}
