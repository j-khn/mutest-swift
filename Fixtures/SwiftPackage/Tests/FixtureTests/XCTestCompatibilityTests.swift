import Fixture
import XCTest

final class XCTestCompatibilityTests: XCTestCase {
    func testFreeShippingOnHighValueOrder() {
        XCTAssertEqual(ShippingRule.price(cents: 12_000, expedited: false, regionCode: "DE"), 0)
    }
}
