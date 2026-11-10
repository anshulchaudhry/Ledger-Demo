import Foundation

private func summaryDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    TransactionRecord.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func summaryRecord(_ id: String, _ amount: Int64, _ type: TransactionType = .expense,
                           _ direction: Direction = .debit, _ category: SpendingCategory = .uncategorized,
                           _ date: Date = summaryDate(2026, 10, 10)) -> TransactionRecord {
    TransactionRecord(id: id, date: date, merchant: "Fictional merchant", bank: .axis, amountPaise: amount,
                      direction: direction, type: type, dateFromSMS: true, manuallyEdited: false, category: category)
}

func monthlySummaryChecks() throws {
    let october = LedgerMonth(containing: summaryDate(2026, 10, 31, 23, 59))
    let rows = [
        summaryRecord("food", 10001, .expense, .debit, .foodDining),
        summaryRecord("grocery", 2099, .expense, .debit, .groceries),
        summaryRecord("unknown-purpose", 33),
        summaryRecord("transfer-out", 900000, .transfer, .debit, .investments),
        summaryRecord("transfer-in", 800000, .transfer, .credit),
        summaryRecord("card-bill", 1000000, .cardPayment, .debit, .shopping),
        summaryRecord("refund", 40000, .refund, .credit, .foodDining),
        summaryRecord("incoming", 50000, .incomingPayment, .credit),
        summaryRecord("categorized-review", 60000, .uncertain, .debit, .investments),
        summaryRecord("unknown-direction", 70000, .expense, .uncertain, .foodDining),
        summaryRecord("inconsistent-expense", 80000, .expense, .credit, .foodDining),
        summaryRecord("inconsistent-refund", 90000, .refund, .debit),
        summaryRecord("previous-last-second", 999999, .expense, .debit, .shopping, october.start.addingTimeInterval(-1)),
        summaryRecord("first-instant", 1, .expense, .debit, .foodDining, october.start),
        summaryRecord("last-instant", 2, .expense, .debit, .investments, october.endExclusive.addingTimeInterval(-1)),
        summaryRecord("next-first-instant", 999999, .expense, .debit, .shopping, october.endExclusive),
    ]
    let summary = try MonthlySummary(month: october, records: rows)
    try check(summary.total(.expenses).amountPaise == 12136 && summary.total(.expenses).count == 5, "exact integer paise with all non-expenses and reviews excluded")
    try check(summary.records.count == 14 && summary.excludedCount == 9, "monthly visible/excluded counts partition saved records")
    try check(summary.records.filter(\.needsReview).count == 4, "categorized, uncertain and inconsistent records stay in review")
    try check(summary.total(.category(.uncategorized)).amountPaise == 33, "uncategorized expenses retained")
    try check(summary.total(.category(.foodDining)).amountPaise == 10002, "refunds cannot enter category total")
    try check(summary.total(.category(.investments)).amountPaise == 2 && summary.total(.category(.investments)).count == 1,
              "Investments chart and drill-through count only confirmed expenses")
    try check(summary.total(.refunds).amountPaise == 40000 && summary.total(.refunds).count == 1, "consistent refunds separate without netting")
    try check(summary.total(.incomingPayments).amountPaise == 50000, "incoming separate from expenses")
    try check(summary.total(.transfers).count == 2 && summary.total(.cardPayments).amountPaise == 1000000, "both transfer directions and card payment excluded")
    var categorySum: Int64 = 0
    var categoryCount = 0
    for category in SpendingCategory.allCases {
        categorySum += summary.total(.category(category)).amountPaise
        categoryCount += summary.total(.category(category)).count
    }
    try check(categorySum == summary.total(.expenses).amountPaise && categoryCount == 5, "categories reconcile with confirmed expense list")
    for bucket in [MonthlyBucket.expenses, .refunds, .incomingPayments, .transfers, .cardPayments] + SpendingCategory.allCases.map({ .category($0) }) {
        let filter = MonthlyTransactionFilter(month: october, bucket: bucket)
        let list = rows.filter(filter.includes)
        try check(list.count == summary.total(bucket).count, "drill-through count matches summary")
        try check(list.reduce(Int64(0)) { $0 + $1.amountPaise } == summary.total(bucket).amountPaise, "drill-through amount matches summary")
    }
    let reviewList = rows.filter(MonthlyTransactionFilter(month: october, bucket: .needsReview).includes)
    let excludedList = rows.filter(MonthlyTransactionFilter(month: october, bucket: .excluded).includes)
    try check(reviewList.count == 4 && excludedList.count == summary.excludedCount, "review/excluded drill-through reconciliation")
    let iso = ISO8601DateFormatter()
    try check(october.start == iso.date(from: "2026-09-30T18:30:00Z"), "Kolkata month start crosses UTC date")
    try check(october.endExclusive == iso.date(from: "2026-10-31T18:30:00Z"), "Kolkata half-open month end")
    try check(october.offset(-1).offset(1) == october, "month navigation round trip")
    let december = LedgerMonth(containing: summaryDate(2026, 12, 1))
    try check(december.offset(1).start == summaryDate(2027, 1, 1), "year rollover")
    let leap = LedgerMonth(containing: summaryDate(2028, 2, 20))
    try check(leap.contains(summaryDate(2028, 2, 29)) && !leap.contains(summaryDate(2028, 3, 1)), "leap month boundary")
    let empty = try MonthlySummary(month: december, records: rows)
    try check(empty.records.isEmpty && empty.firstDate == nil && empty.total(.expenses).amountPaise == 0, "empty month safe zero")
    var fallback = summaryRecord("receipt-date", 51)
    fallback.dateFromSMS = false
    let fallbackSummary = try MonthlySummary(month: october, records: [fallback])
    try check(fallbackSummary.receiptOrEditedDateCount == 1, "date provenance coverage count")
    let large = try MonthlySummary(month: october, records: [summaryRecord("large", 9_007_199_254_740_993), summaryRecord("one-paisa", 1)])
    try check(large.total(.expenses).amountPaise == 9_007_199_254_740_994, "paise exact beyond floating point precision")
    do {
        _ = try MonthlySummary(month: october, records: [summaryRecord("maximum", Int64.max), summaryRecord("overflow", 1)])
        throw CheckFailure.failed("summary must reject integer overflow")
    } catch MonthlySummaryError.amountOverflow { }
}

func monthlySummaryPersistenceChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-summary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let october = LedgerMonth(containing: summaryDate(2026, 10, 1))
    let fixtures = [
        message("AX-AXISBK", "INR 10.01 spent at SYNTHETIC CAFE on 10/10/26. Ref SUMMARY001", "summary-expense"),
        message("AX-AXISBK", "INR 20.02 debited for credit card bill payment on 11/10/26. Ref SUMMARY002", "summary-card"),
        message("VM-ICICIB", "INR 30.03 refunded from SYNTHETIC SHOP on 12/10/26. Ref SUMMARY003", "summary-refund"),
        message("AX-AXISBK", "INR 40.04 spent at SYNTHETIC DELETED on 13/10/26. Ref SUMMARY004", "summary-deleted"),
        message("AX-AXISBK", "INR 50.05 spent at SYNTHETIC STALE on 14/10/26. Ref SUMMARY005", "summary-stale"),
        message("AX-AXISBK", "INR 60.06 debited to BLINK COMMERCE PVT LTD on 15/10/26. Ref SUMMARY006", "summary-pending"),
    ]
    do {
        let store = try TransactionStore(url: url)
        _ = try store.ingest(fixtures)
        var corrected = try store.load().first { $0.amountPaise == 1001 }!
        corrected.amountPaise = 1234
        corrected.category = .foodDining
        try store.save(corrected)
        let deleted = try store.load().first { $0.amountPaise == 4004 }!
        try store.delete(id: deleted.id)
        let reminder = message("AX-AXISBK", "Payment of INR 50.05 for Axis Bank Credit Card XX0001 is due. Ignore if paid.", "summary-stale")
        _ = try store.ingest([reminder])
    }
    let reopened = try TransactionStore(url: url)
    let active = try reopened.load()
    let summary = try MonthlySummary(month: october, records: active)
    try check(active.count == 4 && summary.total(.expenses).amountPaise == 1234, "summary after restart excludes deleted/nontransactions and uses saved correction")
    try check(summary.total(.category(.foodDining)).amountPaise == 1234 && summary.total(.refunds).amountPaise == 3003, "saved category and separate refund reconcile")
    try check(active.contains { $0.category == .groceries && $0.needsReview } && summary.records.filter(\.needsReview).count == 1, "automatic pending category never enters spending")
    _ = try reopened.ingest(Array(fixtures.prefix(4)))
    let repeated = try MonthlySummary(month: october, records: reopened.load())
    try check(repeated.total(.expenses).amountPaise == 1234 && repeated.records.count == 4, "repeat imports preserve monthly corrections, deletion and deduplication")
    var move = try reopened.load().first { $0.isConfirmedExpense }!
    move.date = summaryDate(2026, 9, 30, 23, 59)
    try reopened.save(move)
    let updated = try reopened.load()
    try check(try MonthlySummary(month: october, records: updated).total(.expenses).count == 0, "manual date correction leaves original month")
    try check(try MonthlySummary(month: october.offset(-1), records: updated).total(.expenses).amountPaise == 1234, "manual date correction enters target month")
}
