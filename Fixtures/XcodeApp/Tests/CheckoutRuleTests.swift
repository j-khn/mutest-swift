import XCTest
@testable import MutationFixture

final class CheckoutRuleTests: XCTestCase {
    func testMemberDiscountAppliesAfterCoupon() {
        XCTAssertEqual(CheckoutRule.total(cents: 10_000, member: true, couponPercent: 10), 8_900)
    }

    func testRejectsInvalidCoupon() {
        XCTAssertEqual(CheckoutRule.total(cents: 10_000, member: false, couponPercent: 110), 0)
    }
}
