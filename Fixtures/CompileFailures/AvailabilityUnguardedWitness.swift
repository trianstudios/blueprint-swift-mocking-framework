import ConsumerDomain

func invalidWitness(_ directory: any AvailabilityDirectory) {
    _ = directory.receipt()
}
