import BlueprintMocking
let setup = SyncStubbing<String, String>()
setup.matching(.any).willReturn("runtime-only")
let endpoint = SyncEndpoint(id: EndpointID("runtime-only"), configuration: setup.finish(),
                            failureReporter: FailureReporter { _ in fatalError("Unexpected issue") })
precondition(endpoint.invoke("input") == "runtime-only")
precondition(endpoint.verification(matching: .any).wasCalled(.once).passed)
print("PASS: runtime-only consumer")
