import Foundation
import SQLite3

private func ruleExpense(_ amount: Int, _ guid: String, merchant: String = "Amazon", bank: String = "AX-AXISBK") -> Message {
    message(bank, "INR \(amount) spent at \(merchant) on 15/10/26. Ref RULE\(guid)", guid)
}

func merchantRuleChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let source = ruleExpense(10, "source001")
    let untouched = ruleExpense(11, "source002")
    let manualEmpty = ruleExpense(12, "source003")
    let manualCategory = ruleExpense(13, "source004")
    let categorized = ruleExpense(14, "source005")
    let deleted = ruleExpense(15, "source006")
    var ruleID = ""
    do {
        let store = try TransactionStore(url: url)
        _ = try store.ingest([source, untouched, manualEmpty, manualCategory, categorized, deleted])
        try check(try store.merchantRules().isEmpty, "merchant rule requires opt-in")
        var rows = try store.load()
        let empty = rows.first { $0.amountPaise == 1200 }!
        try store.save(empty)
        var manual = rows.first { $0.amountPaise == 1300 }!
        manual.category = .health
        try store.save(manual)
        try check(try store.merchantRules().isEmpty, "ordinary category correction never creates a rule")
        let alreadyCategorizedID = rows.first { $0.amountPaise == 1400 }!.id
        try withSyntheticSQL(url.path) { try testSQL($0, "UPDATE transactions SET category='groceries' WHERE id='\(alreadyCategorizedID)'") }
        try store.delete(id: rows.first { $0.amountPaise == 1500 }!.id)
        rows = try store.load()
        var original = rows.first { $0.amountPaise == 1000 }!
        original.category = .shopping
        try store.save(original, rememberMerchantCategory: true)
        let rules = try store.merchantRules()
        try check(rules.count == 1 && rules[0].merchant == "Amazon" && rules[0].category == .shopping, "opt-in saves normalized merchant category rule")
        ruleID = rules[0].id
        try check(try store.load().first { $0.amountPaise == 1100 }?.category == .uncategorized, "saving a rule does not silently bulk-change old rows")
    }
    do {
        let reopened = try TransactionStore(url: url)
        try check(try reopened.merchantRules().first?.id == ruleID, "rule survives app restart")
        let repeatResult = try reopened.ingest([source, untouched, manualEmpty, manualCategory, categorized, deleted])
        try check(repeatResult.updated == 1 && repeatResult.inserted == 0, "reimport applies rule only to untouched uncategorized expense")
        var rows = try reopened.load()
        try check(rows.first { $0.amountPaise == 1100 }?.category == .shopping, "untouched expense receives saved rule")
        try check(rows.first { $0.amountPaise == 1200 }?.category == .uncategorized, "manual uncategorized choice stays protected")
        try check(rows.first { $0.amountPaise == 1300 }?.category == .health, "individual category overrides rule")
        try check(rows.first { $0.amountPaise == 1400 }?.category == .groceries, "existing category stays intact even without edit flag")
        try check(!rows.contains { $0.amountPaise == 1500 }, "rule never recreates a deleted transaction")
        let aliases = [
            ruleExpense(21, "alias001", merchant: "AMAZON PAY TEST", bank: "VM-ICICIB"),
            ruleExpense(22, "alias002", merchant: "AMZN MKTPLACE TEST", bank: "JD-IDFCFB"),
            ruleExpense(23, "alias003", merchant: "aMaZoN"),
            ruleExpense(24, "alias004", merchant: "AMAZONAS SERVICES"),
        ]
        _ = try reopened.ingest(aliases)
        rows = try reopened.load()
        try check(rows.filter { [2100,2200,2300].contains($0.amountPaise) }.count == 3 && rows.filter { [2100,2200,2300].contains($0.amountPaise) }.allSatisfy { $0.category == .shopping && !$0.manuallyEdited }, "known aliases across banks receive category without becoming manual edits")
        try check(rows.first { $0.amountPaise == 2400 }?.category == .uncategorized, "rule is not a substring match")
        var rule = try reopened.merchantRules()[0]
        rule.category = .investments
        try reopened.saveMerchantRule(rule)
        let next = ruleExpense(25, "later001")
        _ = try reopened.ingest(aliases + [next])
        rows = try reopened.load()
        try check(rows.first { $0.amountPaise == 2500 }?.category == .investments, "changed rule applies Investments to a future expense")
        try check(rows.first { $0.amountPaise == 2100 }?.category == .shopping, "changing rule preserves previously assigned categories")
        try reopened.removeMerchantRule(id: ruleID)
        let afterRemoval = ruleExpense(26, "later002")
        _ = try reopened.ingest([next, afterRemoval])
        rows = try reopened.load()
        try check(try reopened.merchantRules().isEmpty, "rule removal persists")
        try check(rows.first { $0.amountPaise == 2600 }?.category == .uncategorized && rows.first { $0.amountPaise == 2500 }?.category == .investments, "removing rule affects future categorization without erasing old categories")
    }
    let final = try TransactionStore(url: url)
    try check(try final.merchantRules().isEmpty, "removed rule stays removed after restart")
    try check(try Data(contentsOf: url).range(of: Data(source.text.utf8)) == nil, "merchant rule store excludes full source SMS")
    try check(MerchantIntelligence.ruleKey(for: "  WILLOW   BOOKS ") == MerchantIntelligence.ruleKey(for: "willow books"), "merchant rule matches normalized whitespace and case")
    for invalid in ["Recipient not identified", "9000000000", "Unknown merchant", "Credit card payment", "", "A/c XX0001"] {
        try check(MerchantCategoryRule(merchant: invalid, category: .shopping) == nil, "placeholder and numeric merchant cannot create broad rule")
    }
}

func merchantRuleSafetyChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-rule-safety-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    try store.saveMerchantRule(MerchantCategoryRule(merchant: "Amazon", category: .shopping)!)
    let otherTypes = [
        message("AX-AXISBK", "INR 31 debited to Amazon. Ref SAFE0001", "safe-uncertain"),
        message("AX-AXISBK", "INR 32 debited to Amazon via NEFT. Ref SAFE0002", "safe-transfer"),
        message("AX-AXISBK", "INR 33 debited at Amazon for credit card bill payment. Ref SAFE0003", "safe-card"),
        message("AX-AXISBK", "INR 34 refunded from Amazon. Ref SAFE0004", "safe-refund"),
        message("AX-AXISBK", "INR 35 received from Amazon. Ref SAFE0005", "safe-incoming"),
    ]
    _ = try store.ingest(otherTypes)
    let rows = try store.load()
    try check(rows.count == 5 && rows.filter { $0.type != .uncertain }.allSatisfy { $0.category == .uncategorized } && rows.first { $0.type == .uncertain }?.category == .shopping, "merchant rule may identify debit purpose without categorizing other payment types")
    try check(rows.filter(\.needsReview).count == 1 && rows.filter(\.isConfirmedExpense).isEmpty, "rule does not resolve review or turn card payments into expenses")
    let pendingBefore = rows.first { $0.type == .uncertain }!
    var forbidden = pendingBefore
    forbidden.category = .shopping
    forbidden.merchant = "Fictional invalid teaching attempt"
    do { try store.save(forbidden, rememberMerchantCategory: true); throw CheckFailure.failed("uncertain transaction must not teach rule") }
    catch StoreError.invalidRecord { }
    try check(try store.load().first { $0.id == forbidden.id } == pendingBefore, "invalid rule request preserves transaction")

    let expense = ruleExpense(40, "atomic001", merchant: "O'Reilly Books")
    _ = try store.ingest([expense])
    let original = try store.load().first { $0.amountPaise == 4000 }!
    var correction = original
    correction.category = .shopping
    correction.merchant = "O'Reilly Books"
    try withSyntheticSQL(url.path) { try testSQL($0, "CREATE TRIGGER fail_rule BEFORE INSERT ON merchant_category_rules BEGIN SELECT RAISE(ABORT,'fictional rule write failure'); END") }
    do { try store.save(correction, rememberMerchantCategory: true); throw CheckFailure.failed("save and remember should roll back together") }
    catch StoreError.operationFailed { }
    try check(try store.load().first { $0.id == original.id } == original, "failed rule write rolls back financial correction")
    try check(try store.merchantRules().count == 1, "failed rule write leaves rule list intact")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_rule") }
    try store.save(correction, rememberMerchantCategory: true)
    _ = try store.ingest([ruleExpense(41, "atomic002", merchant: "O'Reilly Books")])
    try check(try store.load().first { $0.amountPaise == 4100 }?.category == .shopping, "bound merchant rule safely handles apostrophes")
    var invalidRule = try store.merchantRules()[0]
    invalidRule.category = .incomeSalary
    do { try store.saveMerchantRule(invalidRule); throw CheckFailure.failed("income category rule should be rejected") }
    catch StoreError.invalidRecord { }

    let miscellaneous = MerchantCategoryRule(merchant: "Swiggy", category: .uncategorized)!
    try store.saveMerchantRule(miscellaneous)
    let food = ruleExpense(42, "atomic003", merchant: "Swiggy")
    _ = try store.ingest([food])
    try check(try store.merchantRules().contains(miscellaneous) && store.load().first { $0.amountPaise == 4200 }?.category == .uncategorized,
              "saved Miscellaneous merchant choice takes priority over a catalog default")
    try check(try store.categorizeAutomatically() == 0 && store.categorySuggestions().allSatisfy { $0.transaction.amountPaise != 4200 },
              "Miscellaneous merchant rule is neither a category update nor a no-op suggestion")
}

func merchantRuleMigrationChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-rule-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    _ = try createLegacyCategoryFixture(at: url)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "ALTER TABLE transactions ADD COLUMN category TEXT")
        try testSQL(database, "UPDATE transactions SET category='health' WHERE deleted=0")
        try testSQL(database, "ALTER TABLE transactions ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0")
        try testSQL(database, "PRAGMA user_version=3")
        try testSQL(database, "CREATE VIEW merchant_category_rules AS SELECT 'fixture' AS merchant_key")
    }
    do { _ = try TransactionStore(url: url); throw CheckFailure.failed("conflicting rule table should stop migration") }
    catch StoreError.operationFailed { }
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try check(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK, "read failed rule migration version")
        try check(sqlite3_step(query) == SQLITE_ROW && sqlite3_column_int(query, 0) == 3, "failed rule migration leaves version unchanged")
        try testSQL(database, "DROP VIEW merchant_category_rules")
    }
    let migrated = try TransactionStore(url: url)
    let row = try migrated.load()[0]
    try check(row.id == "legacy-active" && row.merchant == "Fictional saved correction" && row.category == .health && row.manuallyEdited, "version-three upgrade preserves category and financial edits")
    try check(try migrated.sources(id: "legacy-deleted").count == 1 && migrated.merchantRules().isEmpty, "version-three upgrade preserves deletion identity and starts without inferred rules")
}
