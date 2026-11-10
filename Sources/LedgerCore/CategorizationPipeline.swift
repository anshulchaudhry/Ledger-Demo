import Foundation

package struct CategorizationPipeline {
    package struct Decision: Equatable {
        package let category: SpendingCategory
        package let source: CategorySuggestion.Source
        package let automatic: Bool
        package let reason: String
    }
    package struct UnknownMerchant: Identifiable, Equatable, Sendable {
        package var id: String { merchant }
        package let merchant: String
        package let transactionIDs: Set<String>
        package var count: Int { transactionIDs.count }
    }
    package struct Coverage: Sendable {
        package let categorized: Int
        package let uncategorized: Int
        package let needsReview: Int
        package let pendingCategories: Int
        package let protectedUncategorized: Int
        package let reviewHints: Int
        package let automaticReady: Int
        package let conflictingRules: Int
        package let nonExpenseUncategorized: Int
        package let unknown: [UnknownMerchant]
    }
    private let exact: [String: MerchantCategoryRule]
    private let byEntity: [String: Set<SpendingCategory>]

    package init(rules: [MerchantCategoryRule]) {
        exact = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var groups: [String: Set<SpendingCategory>] = [:]
        for rule in rules {
            if let entry = MerchantCatalog.match(rule.merchant) { groups[entry.id, default: []].insert(rule.category) }
        }
        byEntity = groups
    }

    // Purpose can be known while debit transaction type remains uncertain.
    // Never alter direction/type or the Needs Review gate for spending totals.
    package static func eligible(direction: Direction, type: TransactionType) -> Bool {
        direction == .debit && (type == .expense || type == .uncertain)
    }
    private func conflict(_ merchant: String) -> Bool {
        if let key = MerchantIntelligence.ruleKey(for: merchant), exact[key] != nil { return false }
        guard let entry = MerchantCatalog.match(merchant) else { return false }
        return (byEntity[entry.id]?.count ?? 0) > 1
    }
    package func decision(merchant: String, direction: Direction, type: TransactionType) -> Decision? {
        guard Self.eligible(direction: direction, type: type), MerchantIntelligence.ruleKey(for: merchant) != nil else { return nil }
        if let key = MerchantIntelligence.ruleKey(for: merchant), let rule = exact[key] {
            return Decision(category: rule.category, source: .savedRule, automatic: true, reason: "Your saved merchant rule")
        }
        if let entry = MerchantCatalog.match(merchant) {
            let custom = byEntity[entry.id] ?? []
            guard custom.count <= 1 else { return nil }
            if let category = custom.first {
                return Decision(category: category, source: .savedRule, automatic: true, reason: "Your saved rule for a known \(entry.name) alias")
            }
            guard entry.category != .uncategorized else { return nil }
            // Review-only retail defaults do not classify an uncertain transaction.
            guard entry.automatic || type == .expense else { return nil }
            return Decision(category: entry.category, source: .serviceCatalog, automatic: entry.automatic, reason: "Recognized service: \(entry.name)")
        }
        guard type == .expense, let category = MerchantIntelligence.suggestedCategory(merchant: merchant, type: type) else { return nil }
        return Decision(category: category, source: .merchantHint, automatic: false, reason: "Merchant keyword hint; review what you bought")
    }

    package func coverage(_ records: [TransactionRecord]) -> Coverage {
        var unknown: [String: Set<String>] = [:]
        var protected = 0, hints = 0, ready = 0, conflicts = 0, nonExpense = 0
        for row in records where row.category == .uncategorized {
            if row.manuallyEdited { protected += 1; continue }
            guard row.valid, Self.eligible(direction: row.direction, type: row.type) else { nonExpense += 1; continue }
            if conflict(row.merchant) { conflicts += 1; continue }
            if let result = decision(merchant: row.merchant, direction: row.direction, type: row.type) {
                if result.category == row.category { continue }
                if row.recipientTypeRuleKey != nil && result.source != .savedRule { hints += 1; continue }
                if result.automatic { ready += 1 } else { hints += 1 }
            } else { unknown[row.merchant, default: []].insert(row.id) }
        }
        return Coverage(categorized: records.filter { $0.category != .uncategorized }.count,
            uncategorized: records.filter { $0.category == .uncategorized }.count,
            needsReview: records.filter(\.needsReview).count,
            pendingCategories: records.filter { $0.needsReview && $0.category != .uncategorized }.count,
            protectedUncategorized: protected, reviewHints: hints, automaticReady: ready, conflictingRules: conflicts,
            nonExpenseUncategorized: nonExpense,
            unknown: unknown.map { UnknownMerchant(merchant: $0.key, transactionIDs: $0.value) }
                .sorted { $0.count == $1.count ? $0.merchant < $1.merchant : $0.count > $1.count })
    }
}
