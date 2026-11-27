public func extendBorrowedSpanLifetime() -> Int {
    let escaped: Span<UInt8>
    do {
        let owner: ArraySlice<UInt8> = [2, 4, 8][...]
        escaped = owner.span
    }
    return escaped.count
}
