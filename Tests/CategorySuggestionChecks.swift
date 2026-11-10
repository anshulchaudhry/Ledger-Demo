import Foundation
import SQLite3

private func suggestionExpense(_ merchant: String, _ amount: Int, _ guid: String) -> Message {
    message("AX-AXISBK", "INR \(amount) spent at \(merchant) on 16/10/26. Ref SUGG\(guid)", guid)
}

func categorySuggestionChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-category-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let grocery = suggestionExpense("Willow Grocery", 21, "grocery001")
    let cafe = suggestionExpense("Maple Cafe", 22, "cafe00001")
    let amazon = suggestionExpense("Amazon", 23, "amazon001")
    let categorized = suggestionExpense("Netflix", 24, "already001")
    let unknown = suggestionExpense("UNFAMILIAR VENDOR", 25, "unknown01")
    let deleted = suggestionExpense("Willow Grocery", 26, "deleted01")
    let excluded = suggestionExpense("Maple Cafe", 27, "excluded1")
    let otherTypes = [
        message("AX-AXISBK", "INR 31 debited to Maple Cafe. Ref SUGGOTHER1", "sugg-review"),
        message("AX-AXISBK", "INR 32 debited to Amazon via NEFT. Ref SUGGOTHER2", "sugg-transfer"),
        message("AX-AXISBK", "INR 33 debited at Amazon for credit card bill payment. Ref SUGGOTHER3", "sugg-card"),
        message("AX-AXISBK", "INR 34 refunded from Amazon. Ref SUGGOTHER4", "sugg-refund"),
        message("AX-AXISBK", "INR 35 received from Amazon. Ref SUGGOTHER5", "sugg-incoming"),
    ]
    do {
        let store = try TransactionStore(url: url)
        _ = try store.ingest([grocery, cafe, amazon, categorized, unknown, deleted, excluded] + otherTypes)
        var existing = try store.load().first { $0.amountPaise == 2400 }!
        existing.category = .health
        try store.save(existing)
        let editedCafe = try store.load().first { $0.amountPaise == 2200 }!
        try store.save(editedCafe) // Previously edited, still Uncategorized.
        try store.delete(id: store.load().first { $0.amountPaise == 2600 }!.id)
        try withSyntheticSQL(url.path) { try testSQL($0, "UPDATE transactions SET excluded=1 WHERE amount_paise=2700") }
        try store.saveMerchantRule(MerchantCategoryRule(merchant: "Amazon", category: .billsUtilities)!)
        let suggestions = try store.categorySuggestions()
        try check(suggestions.count == 3, "review only contains recognized uncategorized expenses")
        let grocerySuggestion = suggestions.first { $0.transaction.amountPaise == 2100 }!
        let cafeSuggestion = suggestions.first { $0.transaction.amountPaise == 2200 }!
        let amazonSuggestion = suggestions.first { $0.transaction.amountPaise == 2300 }!
        try check(grocerySuggestion.category == .groceries && grocerySuggestion.source == .merchantHint, "built-in hint available for existing history")
        try check(cafeSuggestion.transaction.manuallyEdited && !grocerySuggestion.transaction.manuallyEdited, "review identifies edited records for unchecked defaults")
        try check(amazonSuggestion.category == .billsUtilities && amazonSuggestion.source == .savedRule, "saved merchant rule overrides built-in review hint")
        let before = try store.load()
        try check(try store.applyCategorySuggestions([grocerySuggestion]) == 1, "apply only selected category")
        let after = try store.load()
        for row in before {
            var expected = row
            if row.id == grocerySuggestion.id { expected.category = .groceries; expected.manuallyEdited = true }
            try check(after.first { $0.id == row.id } == expected, "review changes category and edit flag only")
        }
        try check(try store.merchantRules().count == 1, "batch category acceptance does not implicitly teach rules")
        try check(try store.applyCategorySuggestions([cafeSuggestion, amazonSuggestion], rememberMerchants: true) == 2, "explicit batch approval includes a previously edited record")
        try check(try store.merchantRules().count == 2, "optional remembering commits selected merchant rules")
        let final = try store.load()
        try check(final.first { $0.amountPaise == 2400 }?.category == .health && final.first { $0.amountPaise == 2500 }?.category == .uncategorized,
                  "assigned category and unknown purpose stay intact")
        try check(final.filter(\.needsReview).count == 1 && final.filter { [.transfer,.cardPayment,.refund,.incomingPayment].contains($0.type) }.allSatisfy { $0.category == .uncategorized },
                  "batch category review never clears uncertainty or categorizes non-expense types")
        do { _ = try store.applyCategorySuggestions([grocerySuggestion]); throw CheckFailure.failed("old suggestion should be stale") }
        catch StoreError.staleSuggestions { }
        try check(try store.categorySuggestions().isEmpty, "no unaccepted recognized suggestions remain")
    }
    let reopened = try TransactionStore(url: url)
    try check(try reopened.load().first { $0.amountPaise == 2100 }?.category == .groceries && reopened.merchantRules().count == 2, "accepted categories and optional rules survive restart")
    try check(try Data(contentsOf: url).range(of: Data(grocery.text.utf8)) == nil, "category review never persists original SMS")
}

func categorySuggestionSafetyChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-category-review-safety-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    _ = try store.ingest([suggestionExpense("Willow Grocery", 41, "atomic001"), suggestionExpense("Maple Cafe", 42, "atomic002")])
    let initial = try store.categorySuggestions()
    var edited = initial.first { $0.transaction.amountPaise == 4100 }!.transaction
    edited.merchant = "Fictional changed merchant"
    edited.amountPaise = 4101
    try store.save(edited)
    let afterEdit = try store.load()
    do { _ = try store.applyCategorySuggestions(initial); throw CheckFailure.failed("changed records should invalidate a batch") }
    catch StoreError.staleSuggestions { }
    try check(try store.load() == afterEdit, "stale batch preserves concurrent financial correction without partial changes")
    let current = try store.categorySuggestions()[0]
    try store.saveMerchantRule(MerchantCategoryRule(merchant: "Maple Cafe", category: .entertainment)!)
    do { _ = try store.applyCategorySuggestions([current]); throw CheckFailure.failed("changed rule should invalidate a proposal") }
    catch StoreError.staleSuggestions { }
    let latest = try store.categorySuggestions()[0]
    try check(latest.category == .entertainment && latest.source == .savedRule, "refreshing review picks up current merchant rule")
    do { _ = try store.applyCategorySuggestions([latest, latest]); throw CheckFailure.failed("duplicate selected identities should be rejected") }
    catch StoreError.invalidRecord { }
    try store.delete(id: latest.id)
    do { _ = try store.applyCategorySuggestions([latest]); throw CheckFailure.failed("deleted records should invalidate a proposal") }
    catch StoreError.staleSuggestions { }
    try check(try store.load().count == 1, "review cannot restore a deliberate deletion")

    let rollbackURL = directory.appendingPathComponent("rollback/transactions.sqlite")
    let rollback = try TransactionStore(url: rollbackURL)
    _ = try rollback.ingest([suggestionExpense("Willow Grocery", 51, "rollback1"), suggestionExpense("Maple Cafe", 52, "rollback2")])
    let proposals = try rollback.categorySuggestions()
    let ordered = [proposals.first { $0.transaction.amountPaise == 5100 }!, proposals.first { $0.transaction.amountPaise == 5200 }!]
    let before = try rollback.load()
    try withSyntheticSQL(rollbackURL.path) { try testSQL($0, "CREATE TRIGGER fail_batch_rule BEFORE INSERT ON merchant_category_rules WHEN NEW.merchant='Maple Cafe' BEGIN SELECT RAISE(ABORT,'fictional batch failure'); END") }
    do { _ = try rollback.applyCategorySuggestions(ordered, rememberMerchants: true); throw CheckFailure.failed("batch rule write should fail") }
    catch StoreError.operationFailed { }
    try check(try rollback.load() == before && rollback.merchantRules().isEmpty, "batch failure rolls back earlier categories and rules")
    try withSyntheticSQL(rollbackURL.path) { try testSQL($0, "DROP TRIGGER fail_batch_rule") }
    try check(try rollback.applyCategorySuggestions(ordered, rememberMerchants: true) == 2, "failed category batch safely retries")
}
