private protocol SelfOperand: Sendable {
    func accepts(_ other: Self) -> Bool
}

private func invalidExistentialCall(_ first: any SelfOperand, _ second: any SelfOperand) -> Bool {
    first.accepts(second)
}
