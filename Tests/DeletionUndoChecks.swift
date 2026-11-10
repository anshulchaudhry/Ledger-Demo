import Foundation
import SQLite3

func deletionUndoChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-undo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let source = message("AX-AXISBK", "INR 82.25 spent at FICTIONAL UNDO SHOP on 17/10/26. Ref UNDO001", "undo-source")
    let second = message("AX-AXISBK", "INR 24.50 spent at FICTIONAL UNDO CAFE on 18/10/26. Ref UNDO002", "undo-second")
    let pending = message("JD-IDFCFB", "INR 23 debited and credited on 19/10/26. Ref UNDO003", "undo-pending")
    let store = try TransactionStore(url: url)
    _ = try store.ingest([source, second, pending])
    var corrected = try store.load().first { $0.amountPaise == 8225 }!
    corrected.merchant = "Corrected fictional undo merchant"
    corrected.category = .shopping
    corrected.amountPaise = 9999
    corrected.date = Importer.start.addingTimeInterval(86400)
    corrected.dateFromSMS = false
    try store.save(corrected, rememberMerchantCategory: true)
    corrected = try store.load().first { $0.id == corrected.id }!
    let before = try store.load()
    let aliases = try store.sources(id: corrected.id)
    let rules = try store.merchantRules()
    let snapshot = try store.deleteForUndo(id: corrected.id)
    try check(snapshot == corrected, "undo snapshots all saved fields including category and date provenance")
    try check(try !store.load().contains { $0.id == corrected.id }, "undo deletion immediately hides row")
    try check(try store.merchantRules() == rules, "deletion leaves independent merchant rules intact")
    let redelivery = message(source.sender, source.text, "undo-alias", source.receivedAt.addingTimeInterval(90))
    _ = try store.ingest([source, redelivery, second, pending])
    let reopened = try TransactionStore(url: url)
    try check(try !reopened.load().contains { $0.id == snapshot.id }, "session undo retains durable reimport suppression before restore")
    try check(try reopened.sources(id: snapshot.id).count == aliases.count + 1, "deleted row keeps new source aliases")
    try reopened.restoreDeleted(snapshot)
    try check(try reopened.load().first { $0.id == snapshot.id } == corrected, "explicit undo restores same identity and exact correction")
    try check(try reopened.sources(id: snapshot.id).count == aliases.count + 1, "undo preserves old and newly linked sources")
    _ = try reopened.ingest([source, redelivery, second, pending])
    try check(try reopened.load().first { $0.id == snapshot.id } == corrected, "undo restored correction remains protected on reimport")
    try check(try reopened.load().count == before.count, "undo and reimport do not duplicate transaction")
    let month = LedgerMonth(containing: corrected.date)
    let summary = try MonthlySummary(month: month, records: reopened.load())
    try check(summary.total(.category(.shopping)).amountPaise == corrected.amountPaise, "undo monthly totals restore corrected expense once")
    do { try reopened.restoreDeleted(snapshot); throw CheckFailure.failed("undo refuses second restoration") }
    catch StoreError.invalidRecord { }

    let remaining = try reopened.load().first { $0.amountPaise == 2450 }!
    let pendingRecord = try reopened.load().first(where: \.needsReview)!
    let secondSnapshot = try reopened.deleteForUndo(id: remaining.id)
    let pendingSnapshot = try reopened.deleteForUndo(id: pendingRecord.id)
    try reopened.restoreDeleted(pendingSnapshot)
    try reopened.restoreDeleted(secondSnapshot)
    try check(try reopened.load().first { $0.id == remaining.id } == remaining, "multiple deletions restore untouched edit flag and original fields")
    let restoredPending = try reopened.load().first { $0.id == pendingRecord.id }!
    try check(restoredPending.needsReview && !restoredPending.isConfirmedExpense, "undo never confirms uncertainty")

    try withSyntheticSQL(url.path) { try testSQL($0, "CREATE TRIGGER reject_undo_delete BEFORE UPDATE ON transactions WHEN NEW.deleted=1 BEGIN SELECT RAISE(ABORT,'synthetic deletion failure'); END") }
    do { _ = try reopened.deleteForUndo(id: corrected.id); throw CheckFailure.failed("undo delete failure propagates") }
    catch StoreError.operationFailed { }
    try check(try reopened.load().first { $0.id == corrected.id } == corrected, "failed deletion leaves all original fields intact")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER reject_undo_delete") }
    let final = try reopened.deleteForUndo(id: corrected.id)
    try withSyntheticSQL(url.path) { try testSQL($0, "CREATE TRIGGER reject_undo_restore BEFORE UPDATE ON transactions WHEN NEW.deleted=0 AND OLD.deleted=1 BEGIN SELECT RAISE(ABORT,'synthetic restore failure'); END") }
    do { try reopened.restoreDeleted(final); throw CheckFailure.failed("undo restore failure propagates") }
    catch StoreError.operationFailed { }
    try check(try !reopened.load().contains { $0.id == corrected.id }, "failed undo leaves deletion suppressed")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER reject_undo_restore") }
    try reopened.restoreDeleted(final)
    try check(try reopened.load().first { $0.id == corrected.id } == corrected, "failed undo can be retried safely")
    try reopened.delete(id: corrected.id)
    let bytes = try Data(contentsOf: url)
    try check(bytes.range(of: Data(source.text.utf8)) == nil, "undo does not persist full SMS")
    try withSyntheticSQL(url.path) { database in
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT date,merchant,bank,amount_paise,direction,type,date_from_sms,category FROM transactions WHERE deleted=1", -1, &query, nil) == SQLITE_OK, let query else { throw CheckFailure.failed("undo tombstone query") }
        defer { sqlite3_finalize(query) }
        try check(sqlite3_step(query) == SQLITE_ROW, "final deletion retains suppression tombstone")
        try check((0..<8).allSatisfy { sqlite3_column_type(query, Int32($0)) == SQLITE_NULL }, "undo keeps deleted financial fields scrubbed on disk")
        try check(sqlite3_step(query) == SQLITE_DONE, "one tombstone after undo sequence")
    }
}
