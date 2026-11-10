import Foundation

// Calendar months and every drill-through use the same half-open Kolkata range.
package struct LedgerMonth: Hashable, Comparable, Sendable {
    package let start: Date
    package init(containing date: Date) {
        start = TransactionRecord.calendar.dateInterval(of: .month, for: date)!.start
    }
    package var endExclusive: Date {
        TransactionRecord.calendar.date(byAdding: .month, value: 1, to: start)!
    }
    package func contains(_ date: Date) -> Bool { date >= start && date < endExclusive }
    package func offset(_ months: Int) -> LedgerMonth {
        LedgerMonth(containing: TransactionRecord.calendar.date(byAdding: .month, value: months, to: start)!)
    }
    package var label: String {
        var style = Date.FormatStyle().month(.wide).year()
        style.timeZone = Importer.timeZone
        return start.formatted(style)
    }
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.start < rhs.start }
}

package enum MonthlyBucket: Hashable, Sendable {
    case all, expenses, category(SpendingCategory), refunds, incomingPayments, transfers, cardPayments, needsReview, excluded

    package func includes(_ row: TransactionRecord) -> Bool {
        switch self {
        case .all: true
        case .expenses: row.isConfirmedExpense
        case .category(.incomeSalary):
            row.category == .incomeSalary && !row.needsReview && row.direction == .credit &&
                (row.type == .incomingPayment || row.type == .transfer)
        case .category(let category): row.isConfirmedExpense && row.category == category
        case .needsReview: row.needsReview
        case .excluded: !row.isConfirmedExpense
        case .refunds: !row.needsReview && row.type == .refund
        case .incomingPayments: !row.needsReview && row.type == .incomingPayment
        case .transfers: !row.needsReview && row.type == .transfer
        case .cardPayments: !row.needsReview && row.type == .cardPayment
        }
    }
    package var label: String {
        switch self {
        case .all: "All transactions"
        case .expenses: "Confirmed expenses"
        case .category(let category): category.label
        case .refunds: "Refunds"
        case .incomingPayments: "Incoming payments"
        case .transfers: "Transfers"
        case .cardPayments: "Card payments"
        case .needsReview: "Needs Review"
        case .excluded: "Excluded from expenses"
        }
    }
}

package struct MonthlyTransactionFilter: Equatable, Sendable {
    package let month: LedgerMonth
    package let bucket: MonthlyBucket
    package init(month: LedgerMonth, bucket: MonthlyBucket) {
        self.month = month
        self.bucket = bucket
    }
    package func includes(_ row: TransactionRecord) -> Bool { month.contains(row.date) && bucket.includes(row) }
    package var label: String { "\(month.label) · \(bucket.label)" }
}

package enum MonthlySummaryError: Error { case amountOverflow }

// Operates only on active saved rows returned by TransactionStore.load().
// No Messages access, mutation, netting, floating-point amounts or stored totals.
package struct MonthlySummary {
    package struct Total {
        package let count: Int
        package let amountPaise: Int64
        package var formattedAmount: String { (Decimal(amountPaise) / 100).formatted(.currency(code: "INR")) }
    }
    package let month: LedgerMonth
    package let records: [TransactionRecord]
    private let totals: [MonthlyBucket: Total]
    package var firstDate: Date? { records.map(\.date).min() }
    package var lastDate: Date? { records.map(\.date).max() }
    package var receiptOrEditedDateCount: Int { records.filter { !$0.dateFromSMS }.count }
    package var excludedCount: Int { records.count - total(.expenses).count }

    package init(month: LedgerMonth, records: [TransactionRecord]) throws {
        self.month = month
        self.records = records.filter { month.contains($0.date) }
        var totals: [MonthlyBucket: Total] = [:]
        let buckets: [MonthlyBucket] = [.all, .expenses, .refunds, .incomingPayments, .transfers, .cardPayments, .needsReview, .excluded]
            + SpendingCategory.allCases.map { .category($0) }
        for bucket in buckets {
            let rows = self.records.filter(bucket.includes)
            var amount: Int64 = 0
            for row in rows {
                let sum = amount.addingReportingOverflow(row.amountPaise)
                guard !sum.overflow else { throw MonthlySummaryError.amountOverflow }
                amount = sum.partialValue
            }
            totals[bucket] = Total(count: rows.count, amountPaise: amount)
        }
        self.totals = totals
    }

    package func total(_ bucket: MonthlyBucket) -> Total {
        // Every bucket is populated at initialization. Amounts are gross sums,
        // never a signed cash flow; the UI shows only meaningful money groups.
        totals[bucket]!
    }
}
