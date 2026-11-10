import Foundation
import SQLite3

private func createVersionTwoStore(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TABLE transactions (id TEXT PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0, date REAL, merchant TEXT, bank TEXT, amount_paise INTEGER, direction TEXT, type TEXT, date_from_sms INTEGER, edited INTEGER NOT NULL DEFAULT 0, category TEXT)")
        try testSQL(database, "CREATE TABLE sources (source_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id), guid TEXT)")
        try testSQL(database, "CREATE TABLE duplicate_keys (duplicate_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id))")
        try testSQL(database, "CREATE INDEX sources_transaction ON sources(transaction_id)")
        try testSQL(database, "PRAGMA user_version=2")
    }
}

// Simulate already-imported results of an older parser, without raw SMS in the store.
private func seedStaleRecord(_ url: URL, id: String, source: Message,
                             type: String = "incomingPayment", edited: Bool = false, deleted: Bool = false) throws {
    let identity = ImportIdentity.source(source)
    // Fixtures have no reference, so the legacy body key is independent of parsed fields.
    let placeholder = Parser.parse(message("AX-AXISBK", "INR 1 spent at FICTIONAL SHOP"))!
    let duplicate = ImportIdentity.duplicate(source, transaction: placeholder)
    try withSyntheticSQL(url.path) { database in
        if deleted {
            try testSQL(database, "INSERT INTO transactions(id,deleted) VALUES ('\(id)',1)")
        } else {
            try testSQL(database, "INSERT INTO transactions(id,date,merchant,bank,amount_paise,direction,type,date_from_sms,edited,category) VALUES ('\(id)',123456,'Fictional stored merchant','Axis',12300,'\(type == "incomingPayment" ? "credit" : "debit")','\(type)',0,\(edited ? 1 : 0),'groceries')")
        }
        try testSQL(database, "INSERT INTO sources VALUES ('\(identity.key)','\(id)',\(identity.guid.map { "'\($0)'" } ?? "NULL"))")
        try testSQL(database, "INSERT INTO duplicate_keys VALUES ('\(duplicate)','\(id)')")
    }
}

func reconciliationChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-refresh-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    try createVersionTwoStore(url)
    func receipt(_ amount: Int, _ guid: String) -> Message {
        message("AX-AXISBK", "Payment of INR \(amount) has been received towards your Axis Bank Credit Card XX0001 on 20-10-26 - Axis Bank", guid)
    }
    func reminder(_ amount: Int, _ guid: String) -> Message {
        message("AX-AXISBK", "Payment of INR \(amount) for Axis Bank Credit Card XX0001 is due on 22-10-26. Minimum amount due INR 10. Ignore if paid.", guid)
    }
    let payment = receipt(840, "refresh-payment")
    let billReminder = reminder(400, "refresh-reminder")
    let statementReminder = message("VM-ICICIB", "ICICI Bank Credit Card XX0003 Statement is sent to example@example.test. Total of Rs 700.00 or minimum of Rs 100.00 is due by 24-OCT-26.", "refresh-statement")
    try check(Parser.parse(statementReminder) == nil && Parser.isKnownNonTransaction(statementReminder) &&
              Parser.rejectionReason(statementReminder) == "cardBillReminder", "sending a card statement is not a payment")
    let manualPayment = receipt(650, "refresh-manual-payment")
    let manualReminder = reminder(350, "refresh-manual-reminder")
    let deleted = receipt(90, "refresh-deleted")
    let missing = receipt(80, "refresh-missing")
    let empty = message("AX-AXISBK", "", "refresh-empty")
    let noGUID = receipt(70, "")
    for (id, source, type, edited, isDeleted) in [
        ("payment", payment, "incomingPayment", false, false),
        ("reminder", billReminder, "uncertain", false, false),
        ("statement-reminder", statementReminder, "uncertain", false, false),
        ("manual-payment", manualPayment, "expense", true, false),
        ("manual-reminder", manualReminder, "expense", true, false),
        ("deleted", deleted, "expense", false, true),
        ("missing", missing, "incomingPayment", false, false),
        ("empty", empty, "incomingPayment", false, false),
        ("no-guid", noGUID, "incomingPayment", false, false),
    ] {
        try seedStaleRecord(url, id: id, source: source, type: type, edited: edited, deleted: isDeleted)
    }
    do {
        let store = try TransactionStore(url: url)
        let before = try store.load()
        let protectedIDs = ["manual-payment", "manual-reminder", "missing", "empty"]
        let protected = before.filter { protectedIDs.contains($0.id) }
        let input = [payment, billReminder, statementReminder, manualPayment, manualReminder, deleted, empty, noGUID]
        let result = try store.ingest(input)
        try check(result.inserted == 0 && result.updated == 2 && result.excluded == 2, "old records are refreshed without duplicate rows")
        let rows = try store.load()
        let fixed = rows.first { $0.id == "payment" }!
        try check(fixed.type == .cardPayment && fixed.direction == .debit && fixed.amountPaise == 84000 &&
            fixed.merchant == "Credit card payment" && fixed.dateFromSMS && fixed.category == .groceries &&
            !fixed.manuallyEdited && !fixed.isConfirmedExpense, "old receipt becomes card payment while category stays intact")
        try check(rows.first { $0.id == "no-guid" }?.type == .cardPayment, "fallback source identity supports parser refresh")
        try check(!rows.contains { ["reminder", "statement-reminder", "deleted"].contains($0.id) },
                  "known reminders and deliberate deletion stay out of list")
        try check(rows.filter { protectedIDs.contains($0.id) }.sorted { $0.id < $1.id } == protected.sorted { $0.id < $1.id },
                  "manual edits categories absent sources and empty text are preserved")
        let repeated = try store.ingest(input)
        try check(repeated.inserted == 0 && repeated.updated == 0 && repeated.excluded == 0, "refresh is idempotent")
    }
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try check(sqlite3_prepare_v2(database, "SELECT excluded,deleted,amount_paise FROM transactions WHERE id='reminder'", -1, &query, nil) == SQLITE_OK, "inspect fictional parser exclusion")
        try check(sqlite3_step(query) == SQLITE_ROW && sqlite3_column_int(query, 0) == 1 &&
            sqlite3_column_int(query, 1) == 0 && sqlite3_column_int64(query, 2) == 12300,
            "automatic exclusion preserves stored fields and differs from user deletion")
    }
    do {
        let reopened = try TransactionStore(url: url)
        try check(try reopened.load().first { $0.id == "payment" }?.type == .cardPayment, "refreshed classifications survive restart")
        let nowConfirmed = receipt(400, billReminder.guid)
        try check(try reopened.ingest([nowConfirmed, deleted]).updated == 1, "later affirmative source can restore automatic exclusion")
        let rows = try reopened.load()
        try check(rows.contains { $0.id == "reminder" && $0.type == .cardPayment } && !rows.contains { $0.id == "deleted" },
                  "parser restoration never restores deliberate deletion")
    }
}

func futureDebitNoticeChecks() throws {
    let notice = message("JD-IDFCFB", "Your account will be debited with Rs 57.24 towards Example Telecom for the UPI Mandate on 19/10/2026. Pause mandate to stop execution.", "scheduled-telecom")
    let posted = message("JD-IDFCFB", "INR 57.24 paid at Example Telecom on 19/10/2026. Your account will be debited next month for the next mandate.", "posted-telecom")
    let variant = message("AX-AXISBK", "INR 85.00 WILL BE DEBITED from your account tomorrow.", "scheduled-variant")
    try check(Parser.parse(notice) == nil && Parser.isKnownNonTransaction(notice) && Parser.rejectionReason(notice) == "futureDebitNotice",
              "advance mandate debit has a non-transaction diagnostic")
    try check(Parser.parse(variant) == nil, "amount-first future debit wording is skipped across supported banks")
    try check(Parser.parse(posted)?.type == .expense && !Parser.isKnownNonTransaction(posted),
              "a completed payment with a note about the next debit still parses")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-mandate-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    try createVersionTwoStore(url)
    try seedStaleRecord(url, id: "old-notice", source: notice, type: "expense")
    try seedStaleRecord(url, id: "edited-notice", source: variant, type: "expense", edited: true)
    let store = try TransactionStore(url: url)
    let result = try store.ingest([notice, variant, posted])
    let rows = try store.load()
    try check(result.inserted == 1 && result.excluded == 1 && !rows.contains { $0.id == "old-notice" },
              "reimport excludes the untouched notice and retains the separate completed expense")
    try check(rows.first { $0.id == "edited-notice" }?.manuallyEdited == true,
              "reimport preserves a manually corrected record")
    let repeated = try store.ingest([notice, variant, posted])
    try check(repeated.inserted == 0 && repeated.excluded == 0, "repeat import is idempotent")
}

func reconciliationAliasAndRollbackChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-refresh-alias-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    try createVersionTwoStore(url)
    let original = message("AX-AXISBK", "INR 50 spent at FICTIONAL SHOP. Ref ALIAS0001", "refresh-original")
    let alias = message("AX-AXISBK", original.text, "refresh-alias", original.receivedAt.addingTimeInterval(120))
    let store = try TransactionStore(url: url)
    _ = try store.ingest([original, alias])
    let initial = try store.load()[0]
    let repeated = try store.ingest([alias, original])
    try check(repeated.updated == 0 && (try store.load()[0]) == initial, "canonical delivery prevents date changes when aliases reorder")
    // A rejected canonical source must not hide a valid alternate delivery.
    let reminder = message("AX-AXISBK", "Credit card amount due INR 50. Ignore if paid.", original.guid)
    _ = try store.ingest([reminder, alias])
    try check(try store.load().count == 1, "valid alternate source prevents nontransaction exclusion")

    let second = message("AX-AXISBK", "INR 60 spent at FICTIONAL OTHER. Ref ALIAS0002", "refresh-second")
    _ = try store.ingest([second])
    let before = try store.load()
    let fixedFirst = message("AX-AXISBK", "INR 55 spent at FIXED FICTIONAL SHOP. Ref FIXED0001", original.guid)
    let fixedSecond = message("AX-AXISBK", "INR 65 spent at FIXED FICTIONAL OTHER. Ref FIXED0002", second.guid)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TRIGGER fail_refresh BEFORE UPDATE ON transactions WHEN NEW.amount_paise=6500 BEGIN SELECT RAISE(ABORT,'fictional refresh failure'); END")
    }
    do { _ = try store.ingest([fixedFirst, fixedSecond]); throw CheckFailure.failed("refresh batch should roll back") }
    catch StoreError.operationFailed { }
    try check(try store.load() == before, "failed refresh rolls back previous updates atomically")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_refresh") }
    try check(try store.ingest([fixedFirst, fixedSecond]).updated == 2, "failed refresh safely retries")
}
