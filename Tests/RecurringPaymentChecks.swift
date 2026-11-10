import Foundation

func recurringPaymentChecks() throws {
    try check(SpendingCategory(rawValue: "subscriptions") == .subscriptions && SpendingCategory.subscriptions.label == "Recurring Payments",
              "existing subscription storage IDs display as Recurring Payments without migration")
    let pipeline = CategorizationPipeline(rules: [])
    for merchant in ["Netflix", "NETFLIX.COM", "Spotify", "Google One", "GOOGLE*Google One", "GOOGLE*Storage", "GOOGLE*YouTubePremium", "YouTube Premium", "Apple Music", "APPLE MEDIA", "APPLE MEDIA SERVICES", "APPLE*ICLOUD+", "iCloud+"] {
        let decision = pipeline.decision(merchant: merchant, direction: .debit, type: .expense)
        try check(decision?.category == .subscriptions && decision?.automatic == true,
                  "specific recurring service descriptor automatically matches")
    }
    for merchant in ["APPLE.COM/BILL", "ITUNES.COM/BILL", "Google Play", "GOOGLE*YouTube"] {
        let decision = pipeline.decision(merchant: merchant, direction: .debit, type: .expense)
        try check(decision?.category == .subscriptions && decision?.automatic == false,
                  "mixed-use billing descriptor requires explicit approval")
        try check(pipeline.decision(merchant: merchant, direction: .debit, type: .uncertain) == nil,
                  "mixed-use recurring hint cannot categorize an unresolved type")
    }
    for merchant in ["Google", "Google Store", "Apple", "Apple Store", "Pineapple Media", "Apple Media Hardware", "Google One Hardware", "Netflix Furniture", "personal@google", "apple.personal@bank"] {
        try check(pipeline.decision(merchant: merchant, direction: .debit, type: .expense) == nil,
                  "generic brand hardware substring or personal VPA is not a recurring service")
    }
    for type in [TransactionType.transfer, .cardPayment, .refund, .incomingPayment] {
        let direction: Direction = [.refund, .incomingPayment].contains(type) ? .credit : .debit
        try check(pipeline.decision(merchant: "Apple Media", direction: direction, type: type) == nil,
                  "recurring merchant cannot change financial transaction type eligibility")
    }
    try check(pipeline.decision(merchant: "Apple Media", direction: .uncertain, type: .uncertain) == nil,
              "unknown direction remains uncategorized")
    let custom = MerchantCategoryRule(merchant: "GOOGLE*Google One", category: .billsUtilities)!
    try check(custom.id == "merchant-v1|google*google one", "merchant key normalization remains stable")
    try check(CategorizationPipeline(rules: [custom]).decision(merchant: "GOOGLE*Google One", direction: .debit, type: .expense)?.category == .billsUtilities,
              "saved custom rule overrides recurring default")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recurring-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    func purchase(_ merchant: String, _ amount: Int) -> Message {
        message("AX-AXISBK", "INR \(amount) spent at \(merchant) on 20/10/26. Ref RECUR\(amount)000", "recurring-\(amount)")
    }
    let fixtures = [purchase("Netflix", 11), purchase("GOOGLE*Google One", 12), purchase("Apple Media", 13),
                    purchase("Google Play", 14), purchase("APPLE.COM/BILL", 15), purchase("GOOGLE", 16),
                    message("VM-ICICIB", "INR 17 debited to Apple Media on 20/10/26. Ref RECUR17000", "recurring-pending")]
    do {
        let store = try TransactionStore(url: url)
        _ = try store.ingest(fixtures)
        let initial = try store.load()
        for amount in [1100, 1200, 1300, 1700] {
            try check(initial.first { $0.amountPaise == Int64(amount) }?.category == .subscriptions,
                      "import fills recurring purpose for specific services")
        }
        for amount in [1400, 1500, 1600] {
            try check(initial.first { $0.amountPaise == Int64(amount) }?.category == .uncategorized,
                      "generic and mixed-use descriptors remain unassigned on import")
        }
        try check(initial.first { $0.amountPaise == 1700 }?.needsReview == true, "recurring category keeps transaction review pending")
        // Frozen persisted value from existing Ledger versions; no category ID rewrite.
        try withSyntheticSQL(url.path) { database in
            try testSQL(database, "UPDATE transactions SET category='subscriptions',edited=1 WHERE amount_paise=1100")
        }
        try store.saveMerchantRule(MerchantCategoryRule(merchant: "Netflix", category: .subscriptions)!)
        var protected = initial.first { $0.amountPaise == 1200 }!
        protected.category = .uncategorized
        try store.save(protected)
        _ = try store.categorizeAutomatically()
        try check(try store.load().first { $0.amountPaise == 1200 }?.category == .uncategorized,
                  "automatic recurring matching preserves deliberately empty category")
        let proposals = try store.categorySuggestions()
        try check(proposals.contains { $0.transaction.amountPaise == 1400 && $0.category == .subscriptions },
                  "Google marketplace is available for recurring category review")
        let billing = proposals.first { $0.transaction.amountPaise == 1500 }!
        let before = billing.transaction
        try check(try store.applyCategorySuggestions([billing]) == 1, "ambiguous Apple billing category requires explicit batch approval")
        var expected = before
        expected.category = .subscriptions
        expected.manuallyEdited = true
        try check(try store.load().first { $0.id == before.id } == expected,
                  "recurring review changes only category and edit flag")
    }
    let reopened = try TransactionStore(url: url)
    _ = try reopened.ingest(fixtures)
    let saved = try reopened.load()
    let legacy = saved.first { $0.amountPaise == 1100 }!
    try check(legacy.manuallyEdited && legacy.category.label == "Recurring Payments", "legacy subscription selection survives restart and reimport")
    try check(try reopened.merchantRules().first?.category.rawValue == "subscriptions", "legacy recurring rule still uses original persisted category")
    try check(saved.first { $0.amountPaise == 1200 }?.category == .uncategorized && saved.first { $0.amountPaise == 1500 }?.category == .subscriptions,
              "manual blank and explicitly approved recurring categories remain durable")
    let month = LedgerMonth(containing: saved[0].date)
    let summary = try MonthlySummary(month: month, records: saved)
    let list = saved.filter(MonthlyTransactionFilter(month: month, bucket: .category(.subscriptions)).includes)
    try check(summary.total(.category(.subscriptions)).amountPaise == 3900 && list.count == 3,
              "recurring monthly total includes approved expenses and excludes pending type")
    try check(list.reduce(Int64(0)) { $0 + $1.amountPaise } == summary.total(.category(.subscriptions)).amountPaise,
              "recurring summary reconciles exactly with category drill-through")
    try check(try Data(contentsOf: url).range(of: Data(fixtures[0].text.utf8)) == nil, "recurring categorization never stores full source SMS")
}
