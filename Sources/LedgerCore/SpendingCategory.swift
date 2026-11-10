// Stable storage IDs are separate from the labels displayed in the app.
// Transfer/card-payment/incoming status belongs to TransactionType, not category.
package enum SpendingCategory: String, CaseIterable, Sendable {
    case uncategorized
    case foodDining
    case groceries
    case shopping
    case transportation
    case fuel
    case entertainment
    case sportsGames
    case billsUtilities
    case travel
    case health
    // Keep the persisted ID so existing categories and merchant rules survive.
    case subscriptions
    case investments
    case incomeSalary

    package static var expenseCategories: [Self] { allCases.filter { $0 != .incomeSalary } }

    package var label: String {
        switch self {
        case .uncategorized: "Miscellaneous"
        case .foodDining: "Food & Dining"
        case .groceries: "Groceries"
        case .shopping: "Shopping"
        case .transportation: "Transportation"
        case .fuel: "Fuel"
        case .entertainment: "Entertainment"
        case .sportsGames: "Sports & Games"
        case .billsUtilities: "Bills & Utilities"
        case .travel: "Travel"
        case .health: "Health"
        case .subscriptions: "Recurring Payments"
        case .investments: "Investments"
        case .incomeSalary: "Income / Salary"
        }
    }
}
