import Foundation

func categorizationNavigationChecks() throws {
    func record(_ id: String, _ merchant: String, _ type: TransactionType = .expense,
                _ direction: Direction = .debit, _ category: SpendingCategory = .uncategorized,
                edited: Bool = false) -> TransactionRecord {
        TransactionRecord(id: id, date: Importer.start, merchant: merchant, bank: .axis, amountPaise: 100,
            direction: direction, type: type, dateFromSMS: true, manuallyEdited: edited, category: category)
    }
    let records = [
        record("unknown-google", "GOOGLE"),
        record("pending-google", "GOOGLE", .uncertain),
        record("different-service", "GOOGLE*Google One"),
        record("similar-label", "GOOGLE FICTIONAL STORE"),
        record("assigned-google", "GOOGLE", .expense, .debit, .shopping),
        record("protected-google", "GOOGLE", edited: true),
        record("transfer-google", "GOOGLE", .transfer),
        record("unknown-direction-google", "GOOGLE", .uncertain, .uncertain),
    ]
    let pipeline = CategorizationPipeline(rules: [])
    let coverage = pipeline.coverage(records)
    guard let google = coverage.unknown.first(where: { $0.merchant == "GOOGLE" }) else {
        throw CheckFailure.failed("unknown merchant review group exists")
    }
    try check(google.transactionIDs == ["unknown-google", "pending-google"] && google.count == 2,
              "review group contains exact eligible record identities including pending type")
    let linked = records.filter { google.transactionIDs.contains($0.id) }
    try check(linked.count == google.count && !linked.contains { $0.id == "different-service" || $0.id == "similar-label" },
              "review navigation cannot include similarly named merchants or assigned/protected records")
    try check(coverage.unknown.first { $0.merchant == "GOOGLE FICTIONAL STORE" }?.transactionIDs == ["similar-label"],
              "a different merchant has a separate exact review group")
    let allGroupIDs = coverage.unknown.flatMap { $0.transactionIDs }
    try check(Set(allGroupIDs).count == allGroupIDs.count, "review groups have disjoint transaction memberships")
    let learned = CategorizationPipeline(rules: [MerchantCategoryRule(merchant: "GOOGLE", category: .subscriptions)!]).coverage(records)
    try check(!learned.unknown.contains { $0.merchant == "GOOGLE" } && learned.automaticReady == 3,
              "fresh coverage reflects a new rule without retaining stale unknown groups")
    let remaining = pipeline.coverage(records.filter { $0.id != "unknown-google" })
    try check(remaining.unknown.first { $0.merchant == "GOOGLE" }?.transactionIDs == ["pending-google"],
              "refresh removes unavailable rows from review navigation")

    let merchants = ["GOOGLE", "GOOGLE*Google One", "RZP*SWIGGY.COM 123456", "FICTIONAL UNKNOWN VENDOR", "APPLE.COM/BILL"]
    let large = (0..<600).map { index in record("large-\(index)", merchants[index % merchants.count]) }
    let report = pipeline.coverage(large)
    try check(report.unknown.count == 2 && report.automaticReady == 240 && report.reviewHints == 120,
              "large fictional history retains correct unknown automatic and review-hint counts")
    for group in report.unknown {
        let matching = large.filter { $0.merchant == group.merchant }
        try check(group.count == 120 && Set(matching.map(\.id)) == group.transactionIDs,
                  "large merchant group IDs reconcile with its underlying exact transaction list")
    }
}
