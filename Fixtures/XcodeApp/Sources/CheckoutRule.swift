public enum CheckoutRule {
    public static func total(cents: Int, member: Bool, couponPercent: Int) -> Int {
        guard cents >= 0 && couponPercent >= 0 && couponPercent <= 100 else { return 0 }
        let discounted = cents - (cents * couponPercent / 100)
        return member ? discounted - 100 : discounted
    }

    public static func canUseExpress(weightGrams: Int, destinationCode: String) -> Bool {
        weightGrams > 0 && weightGrams <= 25_000 && !destinationCode.isEmpty
    }
}
