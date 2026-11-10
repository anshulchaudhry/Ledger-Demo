package struct CategorySuggestion: Identifiable, Equatable, Sendable {
    package var id: String { transaction.id }
    package let transaction: TransactionRecord
    package let category: SpendingCategory
    package let source: Source

    package enum Source: String, Sendable {
        case savedRule = "Saved merchant rule"
        case serviceCatalog = "Recognized service"
        case merchantHint = "Merchant suggestion"
    }
}
