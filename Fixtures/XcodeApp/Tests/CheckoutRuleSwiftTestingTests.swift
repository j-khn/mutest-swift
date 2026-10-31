import Testing
@testable import MutationFixture

@Suite("Checkout rule behavior")
struct CheckoutRuleSwiftTestingTests {
    @Test("express shipping requires a supported weight and destination")
    func expressEligibility() {
        #expect(CheckoutRule.canUseExpress(weightGrams: 2_000, destinationCode: "DE"))
        #expect(!CheckoutRule.canUseExpress(weightGrams: 30_000, destinationCode: "DE"))
    }

    @Test("evaluates supported weight boundaries", arguments: [2_000, 30_000])
    func parameterizedWeight(weightGrams: Int) {
        #expect(CheckoutRule.canUseExpress(weightGrams: weightGrams, destinationCode: "DE") == (weightGrams <= 25_000))
    }
}
