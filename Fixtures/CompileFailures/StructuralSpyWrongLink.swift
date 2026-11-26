import BlueprintMocking
import ConsumerDomain
import ConsumerDoubles

func invalidStructuralLink(_ destination: StructuralSpyDirectoryMock) {
    let link = AsyncThrowingForwardingLink<Int, String, StructuralSpyFailure>()
    link.bind(to: destination.forwardingTargets.fetch(Int.self))
}
