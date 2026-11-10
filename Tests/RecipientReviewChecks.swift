import Foundation
import SQLite3

private func recipientFixture(_ amount: Int, _ reference: String, name: String = "Maple Market", bank: String = "AX-AXISBK", suffix: String = "") -> Message {
    message(bank, "INR \(amount).00 debited to \(name) on 12/10/26. Ref \(reference). \(suffix)", "recipient-\(reference)")
}

func recipientMiscellaneousChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-misc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TransactionStore(url: directory.appendingPathComponent("transactions.sqlite"))
    _ = try store.ingest([recipientFixture(10, "MISC001", name: "Swiggy")])
    let group = try store.recipientReviewGroups()[0]
    let plan = RecipientReview.Plan(group: group, selectedIDs: [group.records[0].id], type: .expense,
                                    category: .uncategorized, remember: true)
    _ = try store.applyRecipientReview(plan)
    try check(try store.load()[0].category == .foodDining, "batch Miscellaneous choice keeps an existing specific category")
    let savedRule = try store.recipientTypeRules()[0]
    try check(savedRule.category == .uncategorized, "explicit Miscellaneous recipient choice is saved separately from the default")

    let future = recipientFixture(20, "MISC002", name: "Swiggy")
    _ = try store.ingest([future])
    let imported = try store.load().first { $0.amountPaise == 2000 }!
    try check(imported.isConfirmedExpense && imported.category == .uncategorized, "new expense uses the remembered Miscellaneous choice")
    try store.removeRecipientTypeRule(savedRule)
    _ = try store.ingest([future])
    _ = try store.categorizeAutomatically()
    try check(try store.load().first { $0.id == imported.id } == imported, "reimport and automatic categorization keep the previously assigned Miscellaneous category")
}

func recipientReviewChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recipient-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let fixtures = [recipientFixture(10, "MAPLE001"), recipientFixture(20, "MAPLE002"), recipientFixture(30, "MAPLE003"),
        recipientFixture(40, "MAPLE004", bank: "VM-ICICIB"), recipientFixture(50, "MAPLE005", name: "Maple Market Extra"),
        message("AX-AXISBK", "INR 60 credited from Maple Market. Ref MAPLE006", "recipient-credit"),
        message("AX-AXISBK", "INR 70 refunded from Maple Market. Ref MAPLE007", "recipient-refund"),
        message("AX-AXISBK", "INR 80 debited and credited to Maple Market. Ref MAPLE008", "recipient-direction"),
        recipientFixture(90, "MAPLE009", name: "Recipient not identified")]
    let store = try TransactionStore(url: url)
    _ = try store.ingest(fixtures)
    var edited = try store.load().first { $0.amountPaise == 3000 }!
    edited.category = .groceries
    try store.save(edited)
    let initial = try store.load()
    let group = try store.recipientReviewGroups().first { $0.bank == .axis && $0.recipient == "Maple Market" }!
    try check(group.count == 3 && group.records.filter(\.manuallyEdited).count == 1,
              "recipient groups contain exact names in one bank and retain protected edited selections")
    try check(try store.recipientReviewGroups().reduce(0) { $0 + $1.count } == 5,
              "unknown recipients, uncertain direction, incoming and refunds cannot enter recipient confirmation")
    let selected = Set(group.records.filter { !$0.manuallyEdited }.prefix(1).map(\.id))
    let plan = RecipientReview.Plan(group: group, selectedIDs: selected, type: .expense, category: .investments, remember: true)
    try check(plan.proposed.count == 1 && plan.proposed[0].isConfirmedExpense && plan.amountPaise != nil,
              "recipient preview shows only selected expense confirmations and integer-paise impact")
    let beforeSources = try store.sources(id: plan.proposed[0].id)
    try check(try store.applyRecipientReview(plan) == 1 && store.recipientTypeRules().count == 1,
              "selected confirmation and explicit future rule save together")
    let after = try store.load()
    let changed = after.first { selected.contains($0.id) }!
    try check(changed.type == .expense && changed.category == .investments && changed.manuallyEdited && !changed.needsReview,
              "approved type and optional blank category become a saved correction")
    try check(after.filter { !selected.contains($0.id) } == initial.filter { !selected.contains($0.id) },
              "unselected, assigned category, protected edit, other bank and similar name stay unchanged")
    try check(try store.sources(id: changed.id) == beforeSources, "batch confirmation preserves original source identities")
    do { _ = try store.applyRecipientReview(plan); throw CheckFailure.failed("stale recipient preview accepted") }
    catch StoreError.staleSuggestions { }
    _ = try store.ingest(fixtures)
    try check(try store.load().filter { !selected.contains($0.id) } == after.filter { !selected.contains($0.id) },
              "remembering never silently confirms unselected existing rows on reimport")

    let future = recipientFixture(111, "MAPLEFUTURE")
    let futureOtherBank = recipientFixture(112, "MAPLEOTHER", bank: "VM-ICICIB")
    let futureSimilar = recipientFixture(113, "MAPLESIMILAR", name: "Maple Market Place")
    let pending = recipientFixture(114, "MAPLEPENDING", suffix: "Payment pending.")
    _ = try store.ingest([future, futureOtherBank, futureSimilar, pending])
    let imported = try store.load()
    let automatic = imported.first { $0.amountPaise == 11100 }!
    try check(automatic.isConfirmedExpense && automatic.category == .investments && !automatic.manuallyEdited && automatic.recipientTypeRuleKey != nil,
              "new exact reliable match receives remembered type/category with separate automatic provenance")
    for amount: Int64 in [11200, 11300, 11400] {
        try check(imported.first { $0.amountPaise == amount }!.needsReview, "other bank, similar names and pending wording remain uncertain")
    }
    let reopened = try TransactionStore(url: url)
    _ = try reopened.ingest([future])
    try check(try reopened.load().first { $0.id == automatic.id } == automatic,
              "remembered automatic payment survives restart and idempotent reimport")
    let protectedGroup = try reopened.recipientReviewGroups().first { $0.id == group.id }!
    let protectedID = protectedGroup.records.first { $0.amountPaise == 3000 }!.id
    _ = try reopened.applyRecipientReview(.init(group: protectedGroup, selectedIDs: [protectedID], type: .expense, category: .foodDining, remember: false))
    try check(try reopened.load().first { $0.id == protectedID }!.category == .groceries,
              "explicitly including an edited payment confirms type without overwriting its assigned category")
    let previousRule = try reopened.recipientTypeRules()[0]
    var updatedRule = previousRule
    updatedRule.category = .groceries
    try reopened.updateRecipientTypeRule(updatedRule, previous: previousRule)
    try check(try reopened.recipientTypeRules()[0] == updatedRule && reopened.load().first { $0.id == automatic.id }!.category == .investments,
              "managing a remembered category affects future payments without recategorizing prior automatic decisions")
    do { try reopened.updateRecipientTypeRule(previousRule, previous: previousRule); throw CheckFailure.failed("stale recipient rule edit accepted") }
    catch StoreError.staleSuggestions { }
    var conflictingRule = updatedRule
    conflictingRule.type = .transfer; conflictingRule.category = nil
    do { try reopened.updateRecipientTypeRule(conflictingRule, previous: updatedRule); throw CheckFailure.failed("rule manager ignored known conflicting types") }
    catch StoreError.recipientConflict { }
    try reopened.saveMerchantRule(MerchantCategoryRule(merchant: "Maple Market", category: .health)!)
    _ = try reopened.ingest([recipientFixture(118, "MAPLECATEGORY")])
    try check(try reopened.load().first { $0.amountPaise == 11800 }!.category == .health,
              "existing explicit merchant category rule takes priority over remembered recipient purpose")
    _ = try reopened.ingest([
        message("AX-AXISBK", "INR 116 credited from Maple Market. Ref MAPLEINCOMING", "maple-new-incoming"),
        message("AX-AXISBK", "INR 117 refunded from Maple Market. Ref MAPLEREFUND", "maple-new-refund")])
    try check(try reopened.load().first { $0.amountPaise == 11600 }!.type == .incomingPayment && reopened.load().first { $0.amountPaise == 11700 }!.type == .refund,
              "future ordinary credits and refunds never reuse a remembered outgoing type")
    let snapshot = try reopened.deleteForUndo(id: automatic.id)
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try check(sqlite3_prepare_v2(database, "SELECT type_rule_key FROM transactions WHERE deleted=1", -1, &query, nil) == SQLITE_OK && sqlite3_step(query) == SQLITE_ROW && sqlite3_column_type(query, 0) == SQLITE_NULL,
                  "deletion scrubs remembered recipient metadata on disk")
    }
    _ = try reopened.ingest([future])
    try check(try !reopened.load().contains { $0.id == automatic.id }, "remembered matching cannot resurrect a deleted record")
    try reopened.restoreDeleted(snapshot)
    try check(try reopened.load().first { $0.id == automatic.id } == automatic,
              "session Undo restores recipient provenance and all saved finance fields")
    let savedRule = try reopened.recipientTypeRules()[0]
    try reopened.removeRecipientTypeRule(savedRule)
    _ = try reopened.ingest([future, recipientFixture(115, "MAPLEREMOVED")])
    try check(try reopened.load().first { $0.id == automatic.id } == automatic && reopened.load().first { $0.amountPaise == 11500 }!.needsReview,
              "rule removal affects new imports only and leaves prior automatic decisions intact")
    _ = try reopened.ingest([message(future.sender, future.text + " For credit card bill payment.", future.guid)])
    try check(try reopened.load().first { $0.id == automatic.id }!.type == .cardPayment && reopened.load().first { $0.id == automatic.id }!.recipientTypeRuleKey == nil,
              "stronger explicit card-payment source replaces an earlier automatic type without changing identity")

    // All account/type/income decisions remain independent of category rules.
    try check(RecipientTypeRule(recipient: "Maple Market", bank: .axis, type: .incomingPayment) == nil &&
              RecipientTypeRule(recipient: "Maple Market", bank: .axis, type: .expense, category: .incomeSalary) == nil,
              "recipient learning cannot learn incoming/income or refund classifications")
    for generic in ["Recipient not identified", "Unknown", "UPI", "Your account", "Own savings account", "AX-AXISBK", "123456789", "Credit card payment", "Razorpay"] {
        try check(RecipientTypeRule.key(recipient: generic, bank: .axis) == nil, "generic account/sender/processor labels cannot become automatic recipient identities")
    }
    try check(RecipientTypeRule.key(recipient: "  MAPLE   MARKET ", bank: .axis) == RecipientTypeRule.key(recipient: "Maple Market", bank: .axis),
              "exact recipient matching normalizes case and spaces only")
    try check(RecipientTypeRule.key(recipient: "Amazon Pay Variant", bank: .axis) != RecipientTypeRule.key(recipient: "Amazon", bank: .axis),
              "payment-type keys do not introduce descriptor alias learning")
}

func recipientSafetyChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recipient-safety-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    let fixtures = [recipientFixture(1, "SAFE001", name: "Cedar Vendor"), recipientFixture(2, "SAFE002", name: "Cedar Vendor")]
    _ = try store.ingest(fixtures)
    var group = try store.recipientReviewGroups()[0]
    let selected = Set(group.records.map(\.id))
    var plan = RecipientReview.Plan(group: group, selectedIDs: selected, type: .transfer, category: nil, remember: true)
    let original = try store.load()
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TRIGGER fail_recipient_rule BEFORE INSERT ON recipient_type_rules BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
    }
    do { _ = try store.applyRecipientReview(plan); throw CheckFailure.failed("failed recipient rule did not roll back") }
    catch StoreError.operationFailed { }
    try check(try store.load() == original && store.recipientTypeRules().isEmpty, "failed rule save rolls back every selected payment")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_recipient_rule") }
    try check(try store.applyRecipientReview(plan) == 2 && store.load().allSatisfy { !$0.needsReview && !$0.isConfirmedExpense },
              "confirmed transfers leave review but remain outside spending")
    let future = recipientFixture(3, "SAFEFUTURE", name: "Cedar Vendor")
    _ = try store.ingest([future])
    try check(try store.load().first { $0.amountPaise == 300 }!.type == .transfer, "remembered transfer is not learned as spending")

    // An explicit different type later in the SAME batch blocks automatic use,
    // including when the unknown record appears before that explicit evidence.
    let explicit = message("AX-AXISBK", "INR 4 spent at Cedar Vendor. Ref SAFEEXPLICIT", "recipient-conflict")
    _ = try store.ingest([recipientFixture(5, "SAFECONFLICT", name: "Cedar Vendor"), explicit])
    try check(try store.load().first { $0.amountPaise == 500 }!.needsReview && store.load().first { $0.amountPaise == 400 }!.isConfirmedExpense,
              "known types win and in-batch conflicting evidence blocks automatic confirmation regardless of order")
    group = try store.recipientReviewGroups()[0]
    try check(!group.canRemember(.transfer) && !group.canRemember(.expense), "mixed known types cannot teach one automatic type")
    plan = .init(group: group, selectedIDs: Set(group.records.map(\.id)), type: .cardPayment, category: nil, remember: true)
    do { _ = try store.applyRecipientReview(plan); throw CheckFailure.failed("conflicting remembered type accepted") }
    catch StoreError.recipientConflict { }
    let oneTime = RecipientReview.Plan(group: group, selectedIDs: Set(group.records.map(\.id)), type: .cardPayment, category: nil, remember: false)
    _ = try store.applyRecipientReview(oneTime)
    try check(try store.load().first { $0.amountPaise == 500 }!.type == .cardPayment && !store.load().first { $0.amountPaise == 500 }!.isConfirmedExpense,
              "mixed recipients can still receive explicit one-time card-payment corrections")

    // A stronger source classification and unsafe status can invalidate a prior
    // automatic decision, while explicit saved confirmations stay protected.
    let changed = message(future.sender, future.text + " Payment pending.", future.guid)
    _ = try store.ingest([changed])
    try check(try store.load().first { $0.amountPaise == 300 }!.needsReview && store.load().first { $0.amountPaise == 300 }!.recipientTypeRuleKey == nil,
              "changed pending wording cannot retain an automatic confirmation")
    _ = try store.ingest([message(fixtures[0].sender, fixtures[0].text + " Payment pending.", fixtures[0].guid)])
    try check(try store.load().first { $0.amountPaise == 100 }!.type == .transfer,
              "explicit selected-row confirmation remains a protected saved edit")

    let pendingGroup = try store.recipientReviewGroups()[0]
    let invalid = RecipientReview.Plan(group: pendingGroup, selectedIDs: ["not-in-group"], type: .expense, category: nil, remember: false)
    do { _ = try store.applyRecipientReview(invalid); throw CheckFailure.failed("unrelated selection accepted") }
    catch StoreError.invalidRecord { }
    let invalidIncome = RecipientReview.Plan(group: pendingGroup, selectedIDs: Set(pendingGroup.records.map(\.id)), type: .expense, category: .incomeSalary, remember: false)
    do { _ = try store.applyRecipientReview(invalidIncome); throw CheckFailure.failed("income learned as expense") }
    catch StoreError.invalidRecord { }
    for status in ["failed", "declined", "cancelled", "pending", "scheduled", "initiated", "refunded", "reversed", "will be debited", "not debited", "amount due"] {
        try check(!RecipientTypeRule.allowsAutomatic(recipientFixture(10, "STATUS001", suffix: status)), "unsafe payment statuses cannot trigger automatic recipient learning")
    }
    let staleGroup = try store.recipientReviewGroups()[0]
    let stalePlan = RecipientReview.Plan(group: staleGroup, selectedIDs: Set(staleGroup.records.map(\.id)), type: .transfer, category: nil, remember: false)
    var altered = staleGroup.records[0]
    altered.amountPaise += 1
    try store.save(altered)
    do { _ = try store.applyRecipientReview(stalePlan); throw CheckFailure.failed("changed recipient record accepted stale preview") }
    catch StoreError.staleSuggestions { }
    // A protected correction or deliberate deletion must also outrank the old
    // source when collecting evidence that could block a future remembered rule.
    let protectedSource = message("AX-AXISBK", "INR 41 spent at Willow Friend. Ref PROTECTED001", "protected-type-source")
    _ = try store.ingest([protectedSource, recipientFixture(42, "PROTECTED002", name: "Willow Friend")])
    var protectedRecord = try store.load().first { $0.amountPaise == 4100 }!
    protectedRecord.type = .transfer
    try store.save(protectedRecord)
    let protectedGroup = try store.recipientReviewGroups().first { $0.recipient == "Willow Friend" }!
    _ = try store.applyRecipientReview(.init(group: protectedGroup, selectedIDs: Set(protectedGroup.records.map(\.id)), type: .transfer, category: nil, remember: true))
    let deletedSource = message("AX-AXISBK", "INR 43 spent at Willow Friend. Ref PROTECTED003", "deleted-type-source")
    _ = try store.ingest([deletedSource])
    try store.delete(id: store.load().first { $0.amountPaise == 4300 }!.id)
    _ = try store.ingest([recipientFixture(44, "PROTECTED004", name: "Willow Friend"), protectedSource, deletedSource])
    try check(try store.load().first { $0.amountPaise == 4400 }!.type == .transfer,
              "old sources cannot override a saved type correction or deleted decision when evaluating remembered matches")

}

func recipientMigrationChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-recipient-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let originals = try createLegacyCategoryFixture(at: url)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "ALTER TABLE transactions ADD COLUMN category TEXT")
        try testSQL(database, "UPDATE transactions SET category='health' WHERE deleted=0")
        try testSQL(database, "ALTER TABLE transactions ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0")
        try testSQL(database, "CREATE TABLE merchant_category_rules (merchant_key TEXT PRIMARY KEY, merchant TEXT NOT NULL, category TEXT NOT NULL)")
        try testSQL(database, "PRAGMA user_version=4")
        try testSQL(database, "CREATE VIEW recipient_type_rules AS SELECT 'conflict' AS recipient_key")
    }
    do { _ = try TransactionStore(url: url); throw CheckFailure.failed("recipient migration conflict did not abort") }
    catch StoreError.operationFailed { }
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try check(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK && sqlite3_step(query) == SQLITE_ROW && sqlite3_column_int(query, 0) == 4,
                  "failed recipient migration keeps version four")
        try testSQL(database, "DROP VIEW recipient_type_rules")
    }
    let store = try TransactionStore(url: url)
    let row = try store.load()[0]
    try check(row.id == "legacy-active" && row.merchant == "Fictional saved correction" && row.category == .health && row.manuallyEdited && row.recipientTypeRuleKey == nil,
              "recipient migration preserves all earlier financial corrections without inferring rules")
    try check(try store.recipientTypeRules().isEmpty && store.sources(id: "legacy-deleted").count == 1,
              "migration preserves deletion/source identities and creates no automatic type rules")
    _ = try store.ingest([originals.0, originals.1])
    try check(try store.load().count == 1 && store.load()[0] == row,
              "migration and repeat import retain saved corrections and deletion suppression")
}
