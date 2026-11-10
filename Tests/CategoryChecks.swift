import Foundation
import SQLite3

// Frozen version-1 schema, not the current store's schema creation path.
func createLegacyCategoryFixture(at url: URL, failUpgrade: Bool = false) throws -> (Message, Message) {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let active = message("AX-AXISBK", "INR 123 spent at FICTIONAL ORIGINAL. Ref LEGACY0001", "legacy-active-source")
    let deleted = message("AX-AXISBK", "INR 45 spent at FICTIONAL DELETED. Ref LEGACY0002", "legacy-deleted-source")
    let activeSource = ImportIdentity.source(active)
    let deletedSource = ImportIdentity.source(deleted)
    let activeKey = ImportIdentity.duplicate(active, transaction: Parser.parse(active)!)
    let deletedKey = ImportIdentity.duplicate(deleted, transaction: Parser.parse(deleted)!)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TABLE transactions (id TEXT PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0, date REAL, merchant TEXT, bank TEXT, amount_paise INTEGER, direction TEXT, type TEXT, date_from_sms INTEGER, edited INTEGER NOT NULL DEFAULT 0)")
        try testSQL(database, "CREATE TABLE sources (source_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id), guid TEXT)")
        try testSQL(database, "CREATE TABLE duplicate_keys (duplicate_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id))")
        try testSQL(database, "CREATE INDEX sources_transaction ON sources(transaction_id)")
        try testSQL(database, "INSERT INTO transactions VALUES ('legacy-active',0,123456,'Fictional saved correction','ICICI',12050,'debit','expense',1,1)")
        try testSQL(database, "INSERT INTO transactions(id,deleted) VALUES ('legacy-deleted',1)")
        try testSQL(database, "INSERT INTO sources VALUES ('\(activeSource.key)','legacy-active','\(active.guid)'), ('\(deletedSource.key)','legacy-deleted','\(deleted.guid)')")
        try testSQL(database, "INSERT INTO duplicate_keys VALUES ('\(activeKey)','legacy-active'), ('\(deletedKey)','legacy-deleted')")
        try testSQL(database, "PRAGMA user_version=1")
        if failUpgrade {
            try testSQL(database, "CREATE TRIGGER fail_upgrade BEFORE UPDATE ON transactions BEGIN SELECT RAISE(ABORT,'fictional migration failure'); END")
        }
    }
    return (active, deleted)
}

func categoryMigrationChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-category-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("legacy/transactions.sqlite")
    let (active, deleted) = try createLegacyCategoryFixture(at: url)
    let redelivery = message(active.sender, active.text, "legacy-active-redelivery")
    let deletedRedelivery = message(deleted.sender, deleted.text, "legacy-deleted-redelivery")
    do {
        let migrated = try TransactionStore(url: url)
        let rows = try migrated.load()
        try check(rows.count == 1, "migration retains deletion suppression")
        let row = rows[0]
        try check(row.id == "legacy-active" && row.date == Date(timeIntervalSince1970: 123456) &&
            row.merchant == "Fictional saved correction" && row.bank == .icici && row.amountPaise == 12050 &&
            row.direction == .debit && row.type == .expense && row.dateFromSMS && row.manuallyEdited,
            "migration preserves every preexisting corrected field")
        try check(row.category == .uncategorized, "legacy rows start uncategorized")
        let result = try migrated.ingest([active, redelivery, deleted, deletedRedelivery])
        try check(result.inserted == 0 && result.existing == 4, "migration preserves source and duplicate identities")
        try check(try migrated.sources(id: "legacy-active").count == 2 && migrated.sources(id: "legacy-deleted").count == 2,
                  "migration retains source aliases including tombstones")
        var corrected = row
        corrected.category = .groceries
        try migrated.save(corrected)
    }
    do {
        let reopened = try TransactionStore(url: url)
        _ = try reopened.ingest([active, redelivery])
        let row = try reopened.load()[0]
        try check(row.category == .groceries && row.merchant == "Fictional saved correction", "category correction survives restart migration reopen and reimport")
        try reopened.delete(id: row.id)
        _ = try reopened.ingest([active, redelivery])
        try check(try reopened.load().isEmpty, "categorized deletion stays deleted after import")
    }
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        try check(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM transactions WHERE deleted=1 AND category IS NULL AND merchant IS NULL AND amount_paise IS NULL", -1, &query, nil) == SQLITE_OK,
                  "inspect fictional category tombstones")
        try check(sqlite3_step(query) == SQLITE_ROW && sqlite3_column_int(query, 0) == 2, "deletion clears category as well as finance fields")
    }

    let failedURL = directory.appendingPathComponent("failure/transactions.sqlite")
    _ = try createLegacyCategoryFixture(at: failedURL, failUpgrade: true)
    do { _ = try TransactionStore(url: failedURL); throw CheckFailure.failed("category migration should fail atomically") }
    catch StoreError.operationFailed { }
    try withSyntheticSQL(failedURL.path) { database in
        var version: OpaquePointer?
        defer { sqlite3_finalize(version) }
        try check(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK, "read fictional migration version")
        try check(sqlite3_step(version) == SQLITE_ROW && sqlite3_column_int(version, 0) == 1, "failed migration does not advance schema version")
        var column: OpaquePointer?
        defer { sqlite3_finalize(column) }
        let status = sqlite3_prepare_v2(database, "SELECT category FROM transactions", -1, &column, nil)
        try check(status != SQLITE_OK, "failed migration rolls back added column")
        try testSQL(database, "DROP TRIGGER fail_upgrade")
    }
    let recovered = try TransactionStore(url: failedURL)
    try check(try recovered.load().count == 1 && recovered.load()[0].merchant == "Fictional saved correction", "failed upgrade can retry without losing edits or deletions")
}

func categoryPersistenceChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-category-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let expense = message("AX-AXISBK", "INR 25 spent at FICTIONAL CAFE. Ref CATEGORY001", "category-expense")
    let uncertain = message("JD-IDFCFB", "INR 30 debited and credited. Ref CATEGORY002", "category-uncertain")
    let card = message("AX-AXISBK", "INR 40 debited for credit card bill payment. Ref CATEGORY003", "category-card")
    do {
        let store = try TransactionStore(url: url)
        _ = try store.ingest([expense, uncertain, card])
        var rows = try store.load()
        try check(rows.allSatisfy { $0.category == .uncategorized }, "new imports default to uncategorized without guessing")
        for index in rows.indices {
            rows[index].category = .investments
            try store.save(rows[index])
        }
    }
    let reopened = try TransactionStore(url: url)
    _ = try reopened.ingest([expense, uncertain, card])
    let rows = try reopened.load()
    try check(rows.count == 3 && rows.allSatisfy { $0.category == .investments }, "Investments survives restart and repeated imports")
    try check(rows.filter(\.needsReview).count == 1, "setting category does not clear uncertainty")
    try check(rows.filter(\.isConfirmedExpense).count == 1, "category does not convert card payments or uncertain rows into expenses")
    for category in [SpendingCategory.billsUtilities, .transportation, .uncategorized] {
        var row = try reopened.load().first { $0.type == .expense }!
        row.category = category
        try reopened.save(row)
        try check(try reopened.load().first { $0.id == row.id }?.category == category, "category changes and reset persist")
    }
}
