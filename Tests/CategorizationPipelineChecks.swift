import Foundation
import SQLite3

func categorizationCatalogChecks() throws {
    let mappings: [(String, String, SpendingCategory)] = [
        ("swiggy", "swiggy", .foodDining),
        ("RZP*SWIGGY.COM 123456", "swiggy", .foodDining),
        ("SWIGGY IN E", "swiggy", .foodDining),
        ("SWIGGY_INSTAMART PRIVATE LIMITED", "swiggy-instamart", .groceries),
        ("swiggy.instamart@fictionalbank", "swiggy-instamart", .groceries),
        ("SWIGGYINSTAMART", "swiggy-instamart", .groceries),
        ("PAYU*ZEPTO NOW PRIVATE LIMITED", "zepto", .groceries),
        ("KIRANAKART TECHNOLOGIES PRIVATE LIMITED", "zepto", .groceries),
        ("www.blinkit.com", "blinkit", .groceries),
        ("BLINK COMMERCE PVT LTD", "blinkit", .groceries),
        ("SWISH TECHNOLOGIES PRIVATE LIMITED", "swish", .foodDining),
        ("NETFLIX.COM", "netflix", .subscriptions),
    ]
    let pipeline = CategorizationPipeline(rules: [])
    for (descriptor, entity, category) in mappings {
        try check(MerchantCatalog.match(descriptor)?.id == entity, "catalog recognizes bounded descriptor alias")
        let decision = pipeline.decision(merchant: descriptor, direction: .debit, type: .expense)
        try check(decision?.category == category && decision?.automatic == true, "recognized service has automatic default category")
    }
    for unrelated in ["Swiggy Fashion", "SWIGGYMERCH", "Zeptonic Labs", "Swish Fashion", "Ola Electric", "Apollo Tyres", "PAYTM", "personal@swiggy", "swiggy.personal@bank"] {
        try check(MerchantCatalog.match(unrelated) == nil, "substring personal VPA or unrelated service does not match")
    }
    try check(pipeline.decision(merchant: "BUNDL TECHNOLOGIES PRIVATE LIMITED", direction: .debit, type: .expense) == nil, "shared historical company descriptor stays ambiguous")
    try check(pipeline.decision(merchant: "Amazon", direction: .debit, type: .expense)?.automatic == false, "general retail remains a review hint")
    try check(pipeline.decision(merchant: "Maple Cafe", direction: .debit, type: .expense)?.source == .merchantHint, "generic word remains review-only")
    for type in [TransactionType.transfer, .cardPayment, .refund, .incomingPayment] {
        try check(pipeline.decision(merchant: "Swiggy", direction: type == .refund || type == .incomingPayment ? .credit : .debit, type: type) == nil,
                  "known service does not categorize a different financial type")
    }
    try check(pipeline.decision(merchant: "Swiggy", direction: .uncertain, type: .uncertain) == nil, "unknown direction remains protected")
    let aliasRule = MerchantCategoryRule(merchant: "SWIGGY.COM", category: .entertainment)!
    let withOverride = CategorizationPipeline(rules: [aliasRule])
    try check(withOverride.decision(merchant: "RZP*SWIGGY IN E", direction: .debit, type: .expense)?.category == .entertainment, "user alias rule takes priority over catalog default")
    try check(withOverride.decision(merchant: "Swiggy Instamart", direction: .debit, type: .expense)?.category == .groceries, "food rule cannot bleed into specific grocery service")
    let conflicting = CategorizationPipeline(rules: [aliasRule, MerchantCategoryRule(merchant: "Swiggy", category: .foodDining)!])
    try check(conflicting.decision(merchant: "Swiggy", direction: .debit, type: .expense)?.category == .foodDining, "exact user rule resolves its own descriptor")
    try check(conflicting.decision(merchant: "RZP*SWIGGY IN E", direction: .debit, type: .expense) == nil, "conflicting alias rules require review instead of arbitrary precedence")
}

func categorizationAutomaticChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-auto-pipeline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    func purchase(_ merchant: String, _ amount: Int, _ guid: String) -> Message {
        message("AX-AXISBK", "INR \(amount) spent at \(merchant) on 20/10/26. Ref PIPE\(guid)", guid)
    }
    let sources = [
        purchase("Swiggy", 11, "food0001"), purchase("SWIGGYINSTAMART", 12, "grocery1"),
        purchase("Zepto", 13, "manual01"), purchase("Blinkit", 14, "manual02"),
        purchase("Swish", 15, "assigned"), purchase("Swiggy", 16, "deleted1"),
        purchase("Zepto", 17, "excluded"), purchase("Fictional unknown shop", 18, "unknown1"),
        message("VM-ICICIB", "INR 21 debited to BLINK COMMERCE PVT LTD. Ref PIPEPENDING", "pending01"),
        message("VM-ICICIB", "INR 22 debited and credited to Swiggy. Ref PIPEAMBIG01", "ambig0001"),
        message("VM-ICICIB", "INR 23 received from Swiggy. Ref PIPECREDIT01", "credit001"),
    ]
    let store = try TransactionStore(url: url)
    _ = try store.ingest(sources)
    try check(try store.load().first { $0.amountPaise == 1100 }?.category == .foodDining, "new import automatically categorizes a recognized service")
    try withSyntheticSQL(url.path) { try testSQL($0, "UPDATE transactions SET category='uncategorized',edited=0") }
    var manual = try store.load().first { $0.amountPaise == 1300 }!
    manual.category = .health
    try store.save(manual)
    let manualEmpty = try store.load().first { $0.amountPaise == 1400 }!
    try store.save(manualEmpty)
    try withSyntheticSQL(url.path) { try testSQL($0, "UPDATE transactions SET category='travel' WHERE amount_paise=1500") }
    try store.delete(id: store.load().first { $0.amountPaise == 1600 }!.id)
    try withSyntheticSQL(url.path) { try testSQL($0, "UPDATE transactions SET excluded=1 WHERE amount_paise=1700") }
    let before = try store.load()
    try check(try store.categorizeAutomatically() == 3, "saved-record pipeline fills only eligible untouched empty categories")
    let after = try store.load()
    for row in before {
        var expected = row
        if row.amountPaise == 1100 { expected.category = .foodDining }
        if [1200,2100].contains(row.amountPaise) { expected.category = .groceries }
        try check(after.first { $0.id == row.id } == expected, "automatic purpose changes preserve every financial field and manual edit")
    }
    let pending = after.first { $0.amountPaise == 2100 }!
    try check(pending.category == .groceries && pending.type == .uncertain && pending.needsReview && !pending.isConfirmedExpense,
              "recognized purpose never confirms an uncertain transaction or enters spending totals")
    try check(after.first { $0.amountPaise == 2200 }?.category == .uncategorized && after.first { $0.amountPaise == 2300 }?.category == .uncategorized,
              "ambiguous direction and incoming payments remain separate")
    try check(try store.categorizeAutomatically() == 0, "automatic pipeline is idempotent")
    let report = CategorizationPipeline(rules: []).coverage(after)
    try check(report.protectedUncategorized == 1 && report.pendingCategories == 1 && report.unknown.contains { $0.merchant == "Fictional unknown shop" && $0.count == 1 }, "coverage explains protected rows unknown merchants and pending transaction reviews")
    try store.saveMerchantRule(MerchantCategoryRule(merchant: "SWIGGY.COM", category: .entertainment)!)
    _ = try store.ingest([purchase("PAYU*SWIGGY", 31, "later001")])
    try check(try store.load().first { $0.amountPaise == 3100 }?.category == .entertainment, "future gateway alias uses user rule before service default")
    try check(try store.load().first { $0.amountPaise == 1100 }?.category == .foodDining, "later rule does not rewrite an already assigned category")
    let reopened = try TransactionStore(url: url)
    try check(try reopened.load().first { $0.amountPaise == 1200 }?.category == .groceries && reopened.merchantRules()[0].id == MerchantIntelligence.ruleKey(for: "SWIGGY.COM"), "automatic categories and legacy stable rule keys survive restart")
    try check(try Data(contentsOf: url).range(of: Data(sources[0].text.utf8)) == nil, "automatic pipeline stores no full source SMS")
}

func categorizationRollbackChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-auto-rollback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    _ = try store.ingest([
        message("AX-AXISBK", "INR 10 spent at Swiggy on 30/10/26. Ref AUTOFAIL01", "auto-fail-1"),
        message("AX-AXISBK", "INR 20 spent at Zepto on 29/10/26. Ref AUTOFAIL02", "auto-fail-2"),
    ])
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "UPDATE transactions SET category='uncategorized'")
        try testSQL(database, "CREATE TRIGGER fail_auto BEFORE UPDATE ON transactions WHEN NEW.category='groceries' BEGIN SELECT RAISE(ABORT,'fictional automatic category failure'); END")
    }
    let before = try store.load()
    do { _ = try store.categorizeAutomatically(); throw CheckFailure.failed("automatic pipeline should roll back") }
    catch StoreError.operationFailed { }
    try check(try store.load() == before, "automatic batch failure preserves earlier categories atomically")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_auto") }
    try check(try store.categorizeAutomatically() == 2, "automatic categorization safely retries")
}
