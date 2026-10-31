import Foundation

public enum ShippingRule {
    public static func price(cents: Int, expedited: Bool, regionCode: String) -> Int {
        guard cents >= 0 && !regionCode.isEmpty else { return 0 }
        let base = cents > 10_000 ? 0 : 799
        let surcharge = expedited ? 500 : 0
        return base + surcharge
    }

    public static func eligible(weightGrams: Int, orderCents: Int) -> Bool {
        weightGrams > 0 && (weightGrams <= 20_000 || orderCents >= 15_000)
    }

    public static func record(_ value: String) { print(value) }
}
