import Foundation

package struct TransactionRecord: Identifiable, Equatable, Sendable {
    package let id: String
    package var date: Date
    package var merchant: String
    package var bank: Bank
    package var amountPaise: Int64
    package var direction: Direction
    package var type: TransactionType
    package var dateFromSMS: Bool
    package var manuallyEdited: Bool
    package var category: SpendingCategory = .uncategorized
    package var recipientTypeRuleKey: String? = nil
    package var linkedCardPaymentID: String? = nil
    package var needsReview: Bool { direction == .uncertain || type == .uncertain || !consistent }
    // Spending totals must use this gate, never direction alone.
    package var isConfirmedExpense: Bool { !needsReview && type == .expense }
    package var consistent: Bool {
        // Income is an explicit purpose for money coming in. A category must
        // never hide a debit/expense from spending or turn a refund into salary.
        if category == .incomeSalary && (direction == .debit || type == .expense || type == .cardPayment || type == .refund) { return false }
        switch type {
        case .expense, .cardPayment: return direction == .debit
        case .refund, .incomingPayment: return direction == .credit
        case .transfer: return direction != .uncertain
        case .uncertain: return true
        }
    }
    package var valid: Bool {
        amountPaise > 0 && date.timeIntervalSince1970.isFinite &&
        !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && consistent
    }
    package var reviewExplanation: String {
        ReviewDiagnostics.Reason.forRecord(self)?.explanation ?? "Direction and payment type are confirmed."
    }
    package var formattedAmount: String {
        let prefix = direction == .debit ? "−" : direction == .credit ? "+" : ""
        return prefix + (Decimal(amountPaise) / 100).formatted(.currency(code: "INR"))
    }
    package static func paise(from amount: String) -> Int64? {
        let value = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]{1,12}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let result = NSDecimalNumber(decimal: decimal * 100).int64Value
        return result > 0 ? result : nil
    }
    package static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = Importer.timeZone
        return value
    }()
    package static let dateStyle: Date.FormatStyle = {
        var value = Date.FormatStyle().day().month(.abbreviated)
        value.timeZone = Importer.timeZone
        return value
    }()
}

extension Direction {
    package var label: String {
        switch self {
        case .debit: "Money out"
        case .credit: "Money in"
        case .uncertain: "Uncertain"
        }
    }
}
extension TransactionType {
    package var label: String {
        switch self {
        case .expense: "Expense"
        case .transfer: "Transfer"
        case .cardPayment: "Card payment"
        case .refund: "Refund"
        case .incomingPayment: "Incoming payment"
        case .uncertain: "Uncertain"
        }
    }
}
