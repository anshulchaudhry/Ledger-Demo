import Foundation

func incomeCategoryChecks() throws {
    try check(SpendingCategory(rawValue: "incomeSalary") == .incomeSalary, "income category has a stable additive storage ID")
    try check(!SpendingCategory.expenseCategories.contains(.incomeSalary), "income never appears among spending pie categories")
    try check(MerchantCategoryRule(merchant: "Fictional Employer", category: .incomeSalary) == nil,
              "expense merchant rules cannot teach income onto debits")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-income-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let incomeSource = message("JD-IDFCFB", "Rs. 81.25 received from Fictional Employer on 15/10/26 in A/c XX0002. Ref INCOME001.", "income-tagged")
    let otherSource = message("JD-IDFCFB", "Rs. 82 received from Fictional Employer on 16/10/26 in A/c XX0002. Ref INCOME002.", "income-other")
    let expenseSource = message("AX-AXISBK", "INR 42 spent at FICTIONAL CAFE on 17/10/26. Ref INCOME003", "income-expense")
    let pendingSource = message("JD-IDFCFB", "Rs. 83 debited and credited on 18/10/26. Ref INCOME004.", "income-pending")
    let fixtures = [incomeSource, otherSource, expenseSource, pendingSource]
    let store = try TransactionStore(url: url)
    _ = try store.ingest(fixtures)
    var income = try store.load().first { $0.amountPaise == 8125 }!
    let originalIncome = income
    income.category = .incomeSalary
    try check(income.valid && income.type == .incomingPayment && income.direction == .credit,
              "assigning income purpose preserves incoming direction and type")
    try store.save(income)
    var pending = try store.load().first { $0.amountPaise == 8300 }!
    pending.direction = .credit; pending.type = .uncertain; pending.category = .incomeSalary
    try store.save(pending)
    let month = LedgerMonth(containing: income.date)
    var summary = try MonthlySummary(month: month, records: store.load())
    try check(summary.total(.category(.incomeSalary)).amountPaise == 8125 && summary.total(.category(.incomeSalary)).count == 1,
              "only explicit consistent money-in tags count as income")
    try check(summary.total(.incomingPayments).amountPaise == 16325, "ordinary incoming payment remains separate from assigned income")
    try check(summary.total(.expenses).amountPaise == 4200, "salary never inflates or nets against spending")
    try check(summary.total(.needsReview).count == 1 && pending.needsReview && !pending.isConfirmedExpense,
              "income tag cannot resolve uncertain type")
    let expenseSum = SpendingCategory.expenseCategories.reduce(Int64(0)) { $0 + summary.total(.category($1)).amountPaise }
    try check(expenseSum == summary.total(.expenses).amountPaise, "expense pie reconciles independently of income")
    let filter = MonthlyTransactionFilter(month: month, bucket: .category(.incomeSalary))
    try check(try store.load().filter(filter.includes).map(\.id) == [income.id], "income drill-through excludes ordinary incoming and review records")

    let expense = try store.load().first { $0.amountPaise == 4200 }!
    var invalidExpense = expense; invalidExpense.category = .incomeSalary
    try check(!invalidExpense.valid && invalidExpense.needsReview && !invalidExpense.isConfirmedExpense,
              "income-purpose conflict requires explicit direction/type correction")
    do { try store.save(invalidExpense); throw CheckFailure.failed("expense cannot be saved as salary by category alone") }
    catch StoreError.invalidRecord { }
    try check(try store.load().first { $0.id == expense.id } == expense, "rejected income conflict leaves original expense unchanged")
    for type in [TransactionType.refund, .cardPayment] {
        var conflict = income; conflict.type = type
        conflict.direction = type == .refund ? .credit : .debit
        try check(!conflict.valid, "refunds and bill payments cannot become salary through a category tag")
    }

    income.type = .transfer
    try store.save(income)
    let future = message("JD-IDFCFB", "Rs. 84 received from Fictional Employer on 19/10/26 in A/c XX0002. Ref INCOME005.", "income-future")
    let reopened = try TransactionStore(url: url)
    _ = try reopened.ingest(fixtures + [future])
    let persisted = try reopened.load().first { $0.id == income.id }!
    try check(persisted.category == .incomeSalary && persisted.type == .transfer && persisted.direction == .credit && persisted.manuallyEdited,
              "tagged credit transfer survives restart and reimport without reclassification")
    try check(try reopened.load().first { $0.amountPaise == 8400 }?.category == .uncategorized,
              "new incoming from the same sender is not assumed to be salary")
    summary = try MonthlySummary(month: month, records: reopened.load())
    try check(summary.total(.category(.incomeSalary)).amountPaise == 8125 && summary.total(.transfers).count == 1,
              "explicit credit-transfer income remains visible in its original type list")
    try check(summary.total(.expenses).amountPaise == 4200, "reimport and income tagging leave confirmed spending intact")
    let snapshot = try reopened.deleteForUndo(id: income.id)
    try reopened.restoreDeleted(snapshot)
    try check(try reopened.load().first { $0.id == income.id } == persisted, "income category survives deletion Undo exactly")
    var cleared = persisted; cleared.category = .uncategorized
    try reopened.save(cleared)
    summary = try MonthlySummary(month: month, records: reopened.load())
    try check(summary.total(.category(.incomeSalary)).count == 0 && summary.total(.transfers).count == 1,
              "clearing the income tag preserves underlying type and direction")
    try check(originalIncome.category == .uncategorized, "existing incoming records start unchanged")
}
