import Fixture
import Testing

@Suite("Shipping rules")
struct ShippingRuleTests {
    @Test("charges the standard price for a normal order")
    func standardPrice() {
        #expect(ShippingRule.price(cents: 2_000, expedited: false, regionCode: "DE") == 799)
    }

    @Test("adds the expedited surcharge")
    func expeditedPrice() {
        #expect(ShippingRule.price(cents: 2_000, expedited: true, regionCode: "DE") == 1_299)
    }

    @Test("rejects negative weight")
    func rejectsNegativeWeight() {
        #expect(!ShippingRule.eligible(weightGrams: -1, orderCents: 20_000))
    }
}
