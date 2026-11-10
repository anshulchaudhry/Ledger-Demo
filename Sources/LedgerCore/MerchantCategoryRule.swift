import Foundation

package struct MerchantCategoryRule: Identifiable, Equatable, Sendable {
    package let id: String
    package let merchant: String
    package var category: SpendingCategory

    package init?(merchant: String, category: SpendingCategory) {
        guard let key = MerchantIntelligence.ruleKey(for: merchant), category != .incomeSalary else { return nil }
        self.id = key
        self.merchant = MerchantIntelligence.canonicalName(merchant)
        self.category = category
    }
}
