public final class FrozenQuoteSDK: Sendable {
    private let surcharge: Int

    public init(surcharge: Int) {
        self.surcharge = surcharge
    }

    public func quote(value: Int) -> Int {
        value + hiddenFee(value: value)
    }

    private func hiddenFee(value: Int) -> Int {
        value > 0 ? surcharge : 0
    }

    public static func version(value: Int) -> Int { value }
}
