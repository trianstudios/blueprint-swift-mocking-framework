import ConsumerDomain
import ConsumerDoubles

func retainForLater(_ work: @escaping () -> Void) {}

func invalidInoutRetention(_ stubs: InoutSpyDirectoryMock.Stubs) {
    stubs.adjust(.any).willAnswer { (value: inout Int) throws(InoutSpyFailure) in
        retainForLater { value += 1 }
        return value
    }
}
