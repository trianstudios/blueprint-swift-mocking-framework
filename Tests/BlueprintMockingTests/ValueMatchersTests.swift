import Foundation
import Testing
import BlueprintMocking

@Test func RUN008_unorderedCollectionsPreserveDuplicates() {
    let matcher = Matcher<[Int]>.unorderedElements([.equal(1), .equal(1), .equal(2)])
    #expect(matcher.matches([2, 1, 1]))
    #expect(!matcher.matches([2, 2, 1]))
    #expect(!matcher.matches([2, 1]))
    #expect(!matcher.matches([2, 1, 1, 1]))
    #expect(Matcher<[Int]>.unorderedElements([]).matches([]))
}

@Test func RUN008_overlappingPredicatesFindDistinctElements() {
    let flexible = Matcher<[Int]>.unorderedElements([.any, .equal(1)])
    #expect(flexible.matches([1, 2]))
    #expect(flexible.matches([2, 1]))
    #expect(!flexible.matches([2, 2]))

    let chain = Matcher<[Int]>.unorderedElements([
        .satisfying { $0 == 1 || $0 == 2 },
        .satisfying { $0 == 2 || $0 == 3 },
        .equal(1),
    ])
    #expect(chain.matches([1, 2, 3]))
    #expect(!chain.matches([1, 3, 3]))
}

@Test func RUN008_multisetMatchingAgreesWithExhaustiveSmallAssignmentModel() {
    let positions = [0, 1, 2]
    let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for graph in 0..<(1 << 9) {
        let predicates = positions.map { predicate in
            Matcher<Int>.satisfying { value in graph & (1 << (predicate * 3 + value)) != 0 }
        }
        let expected = permutations.contains { values in
            positions.allSatisfy { predicate in predicates[predicate].matches(values[predicate]) }
        }
        #expect(Matcher<[Int]>.unorderedElements(predicates).matches(positions) == expected)
    }
}

@Test func RUN008_countsOrderingAndContainmentWorkOnSlices() {
    let slice = [0, 2, 3, 5, 0][1...3]
    let ordered = Matcher<ArraySlice<Int>>.orderedElements([.equal(2), .any, .equal(5)])
    #expect(ordered.matches(slice))
    #expect(!ordered.matches([5, 3, 2][...]))
    #expect(!ordered.matches(slice.dropLast()))

    let count = Matcher<ArraySlice<Int>>.count(.range(2...4).and(CallCount.exactly(4).not()))
    #expect(count.matches(slice))
    #expect(!count.matches(slice.dropLast(2)))
    #expect(Matcher<ArraySlice<Int>>.containsElement(3).matches(slice))
    #expect(Matcher<ArraySlice<Int>>.anyElement(.inRange(2..<3)).matches(slice))
    #expect(!Matcher<ArraySlice<Int>>.allElements(.inRange(2..<5)).matches(slice))
    #expect(Matcher<ArraySlice<Int>>.allElements(.inRange(2...5)).matches(slice))
    #expect(Matcher<[Int]>.allElements(.equal(2)).matches([]))
    #expect(!Matcher<[Int]>.anyElement(.equal(2)).matches([]))
    #expect(!Matcher<Int>.openRange(2, 5).matches(2))
    #expect(Matcher<Int>.openRange(2, 5).matches(3))
    #expect(!Matcher<Int>.openRange(2, 5).matches(5))
}

@Test func RUN008_dictionaryEntryDistinguishesMissingKeyFromPresentNil() {
    let entries: [String: Int?] = ["present": nil, "number": 9]
    #expect(Matcher<[String: Int?]>.entry("present", matching: .isNil()).matches(entries))
    #expect(!Matcher<[String: Int?]>.entry("missing", matching: .isNil()).matches(entries))
    #expect(Matcher<[String: Int?]>.entry("number", matching: .nonNil(.equal(9))).matches(entries))
}

private final class LocalValue {
    var value: Int
    init(_ value: Int) { self.value = value }
}

@Test @MainActor func RUN008_actorCollectionMatchingUsesLocalValues() {
    let value = LocalValue(1)
    let copy = LocalValue(1)
    let matcher = MainActorMatcher<[LocalValue]>.unorderedElements([
        .satisfying { $0.value == value.value },
        .identical(to: value),
    ])
    #expect(matcher.matches([value, copy]))
    #expect(!matcher.matches([copy, copy]))
    #expect(MainActorMatcher<[LocalValue]>.count(.once).matches([copy]))
    #expect(MainActorMatcher<[LocalValue]>.orderedElements([.identical(to: value)]).matches([value]))
    #expect(MainActorMatcher<[LocalValue]>.allElements(.any).matches([value]))
    #expect(MainActorMatcher<[LocalValue]>.anyElement(.identical(to: value)).matches([value]))
    #expect(MainActorMatcher<[String: LocalValue]>.entry("value", matching: .identical(to: value))
        .matches(["value": value]))
}

@Test func RUN008_stringAlternativesPreserveAnchorsOptionsAndLocale() throws {
    let input = "Résumé CAFÉ end"
    #expect(Matcher<String>.prefix("résumé ", options: .caseInsensitive).matches(input))
    #expect(!Matcher<String>.prefix("CAFÉ", options: .caseInsensitive).matches(input))
    #expect(Matcher<String>.suffix("END", options: .caseInsensitive).matches(input))
    #expect(!Matcher<String>.suffix("CAFÉ").matches(input))
    #expect(Matcher<String>.substring("cafe", options: [.caseInsensitive, .diacriticInsensitive])
        .matches(input))
    #expect(!Matcher<String>.substring("cafe").matches(input))
    #expect(Matcher<String>.prefix("ı", options: .caseInsensitive, locale: Locale(identifier: "tr_TR"))
        .matches("Istanbul"))
    #expect(Matcher<String>.prefix("").matches(""))
    #expect(Matcher<String>.suffix("").matches("value"))
    #expect(Matcher<String>.substring("").matches("value"))

    let expression = try Matcher<String>.regularExpression(#"^(?:café|tea)\s+\d+$"#,
                                                            options: .caseInsensitive)
    #expect(expression.matches("CAFÉ 4"))
    #expect(!expression.matches("order CAFÉ 4"))
    #expect(throws: (any Error).self) {
        _ = try Matcher<String>.regularExpression("(")
    }
}

@Test @MainActor func RUN008_actorStringMatchingUsesTheSameRules() throws {
    #expect(MainActorMatcher<String>.prefix("pay", options: .caseInsensitive).matches("PAY 20"))
    #expect(MainActorMatcher<String>.suffix("20").matches("PAY 20"))
    #expect(MainActorMatcher<String>.substring("AY").matches("PAY 20"))
    let expression = try MainActorMatcher<String>.regularExpression(#"\d+$"#)
    #expect(expression.matches("PAY 20"))
    #expect(!expression.matches("20 PAY"))
}

@Test func RUN008_floatingToleranceHandlesSpecialValuesAndOverflow() {
    let nearOne = Matcher<Double>.approximately(1, absoluteTolerance: 0.125)
    #expect(nearOne.matches(1.125))
    #expect(!nearOne.matches(1.25))
    let relative = Matcher<Double>.approximately(100, relativeTolerance: 0.1)
    #expect(relative.matches(110))
    #expect(!relative.matches(120))

    let largest = Double.greatestFiniteMagnitude
    let hugeDifference = Matcher<Double>.approximately(largest, absoluteTolerance: largest,
                                                        relativeTolerance: 1.5)
    #expect(!hugeDifference.matches(-largest))
    #expect(Matcher<Double>.approximately(largest, relativeTolerance: 2).matches(-largest))
    #expect(!Matcher<Double>.approximately(.nan).matches(.nan))
    #expect(Matcher<Double>.approximately(.nan, options: .matchNaNs).matches(.nan))
    #expect(!Matcher<Double>.approximately(.nan, options: .matchNaNs).matches(0))
    #expect(!Matcher<Double>.approximately(0, options: .matchNaNs).matches(.nan))
    #expect(Matcher<Double>.approximately(.infinity).matches(.infinity))
    #expect(!Matcher<Double>.approximately(.infinity).matches(-.infinity))
    #expect(!Matcher<Double>.approximately(.infinity).matches(largest))
    #expect(!Matcher<Double>.approximately(.infinity, options: .rejectInfinities).matches(.infinity))
    #expect(Matcher<Double>.approximately(0.0).matches(-0.0))
    #expect(!Matcher<Double>.approximately(0.0, options: .distinguishSignedZero).matches(-0.0))
}

@Test @MainActor func RUN008_actorFloatingMatcherSharesToleranceAndPolicies() {
    let predicate = MainActorMatcher<Float>.approximately(1, absoluteTolerance: 0.25,
                                                           relativeTolerance: 0.1)
    #expect(predicate.matches(1.25))
    #expect(!predicate.matches(1.5))
    #expect(!predicate.matches(.infinity))
    #expect(MainActorMatcher<Float>.approximately(.nan, options: .matchNaNs).matches(.nan))
    #expect(!MainActorMatcher<Float>.approximately(0, options: .distinguishSignedZero).matches(-0.0))
}
