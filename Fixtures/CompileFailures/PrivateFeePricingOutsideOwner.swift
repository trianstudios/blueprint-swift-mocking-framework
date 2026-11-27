extension OwnedFeeRules {
    func inaccessibleOutsideOwnerFile(base: Int) -> Int {
        addSurcharge(to: base)
    }
}
