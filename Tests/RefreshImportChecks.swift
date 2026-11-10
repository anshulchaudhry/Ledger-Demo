import Foundation

func refreshImportChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-refresh-window-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let store = try TransactionStore(url: url)
    let start = ImportWindow.defaultStart
    let day: TimeInterval = 24 * 60 * 60
    let firstCutoff = start.addingTimeInterval(10 * day + 7200)
    let secondCutoff = firstCutoff.addingTimeInterval(3600)
    let old = message("AX-AXISBK", "INR 15 spent at FICTIONAL JULY SHOP. Ref REFRESHJULY", "refresh-july", start.addingTimeInterval(-1))
    let saved = message("AX-AXISBK", "INR 20 spent at FICTIONAL SAVED SHOP. Ref REFRESHSAVED", "refresh-saved", firstCutoff.addingTimeInterval(-60))
    let late = message("AX-AXISBK", "INR 21 spent at FICTIONAL LATE SHOP. Ref REFRESHLATE", "refresh-late", firstCutoff.addingTimeInterval(-day))
    let onBoundary = message("AX-AXISBK", "INR 22 spent at FICTIONAL NEW SHOP. Ref REFRESHNEW", "refresh-new", firstCutoff)
    let after = message("AX-AXISBK", "INR 23 spent at FICTIONAL NEXT SHOP. Ref REFRESHNEXT", "refresh-next", secondCutoff)

    _ = try store.ingest([old])
    let standalone = ImportWindow(start: start.addingTimeInterval(20 * day), endExclusive: start.addingTimeInterval(21 * day))
    _ = try store.ingest([], window: standalone)
    let initialHistory = try store.importHistory()
    try check(initialHistory.refreshThrough == nil && initialHistory.refreshWindow(now: firstCutoff)?.start == start,
              "a manual backfill after a gap cannot skip the initial August catch-up")

    // Model a manual scan saved by an older build with the end of the selected
    // day in its history, even though Messages was scanned earlier that day.
    let manual = ImportWindow(from: start, through: firstCutoff)!
    _ = try store.ingest([saved], window: manual)
    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "UPDATE import_scans SET completed_at=\(firstCutoff.timeIntervalSince1970) WHERE start=\(start.timeIntervalSince1970)")
        try testSQL(database, "ALTER TABLE import_scans DROP COLUMN refresh_completed_at")
        try testSQL(database, "PRAGMA user_version=7")
    }
    let reopened = try TransactionStore(url: url)
    let history = try reopened.importHistory()
    let delta = history.refreshWindow(now: secondCutoff)!
    try check(history.refreshThrough == firstCutoff && history.lastRefreshAt == nil &&
              history.scannedWindows.count == 2 && history.scannedWindows.first?.endExclusive == firstCutoff &&
              delta.start == firstCutoff.addingTimeInterval(-2 * day) && delta.endExclusive == secondCutoff,
              "refresh resumes at the durable scan boundary with a two-day overlap and clips old same-day scans")

    try withSyntheticSQL(url.path) { database in
        try testSQL(database, "CREATE TRIGGER fail_refresh_scan BEFORE INSERT ON import_scans BEGIN SELECT RAISE(ABORT,'fictional refresh failure'); END")
    }
    do { _ = try reopened.ingest([late, onBoundary], window: delta, isRefresh: true); throw CheckFailure.failed("failed refresh must be reported") }
    catch StoreError.operationFailed { }
    try check(try reopened.importHistory().refreshThrough == firstCutoff && reopened.importHistory().lastRefreshAt == nil && reopened.load().count == 2,
              "failed refresh advances neither the boundary nor the saved transactions")
    try withSyntheticSQL(url.path) { try testSQL($0, "DROP TRIGGER fail_refresh_scan") }

    let result = try reopened.ingest([old, saved, late, onBoundary, after], window: delta, isRefresh: true)
    try check(result.inserted == 2 && result.existing == 1 && result.candidates == 3,
              "refresh picks up late SMS and the previous end boundary, deduplicates overlap, and leaves its own upper boundary for later")
    try check(try reopened.importHistory().refreshThrough == secondCutoff && reopened.load().count == 4,
              "a successful refresh advances to its scan cutoff and preserves older saved records")
    let lastRefresh = try TransactionStore(url: url).importHistory().lastRefreshAt
    try check(lastRefresh != nil, "last successful refresh time survives reopening")
    _ = try reopened.ingest([saved, late, onBoundary], window: delta)
    try check(try reopened.importHistory().lastRefreshAt == lastRefresh,
              "manual reimport of the same range preserves the last refresh time")
    let later = secondCutoff.addingTimeInterval(60)
    let next = try reopened.importHistory().refreshWindow(now: later)!
    try check(try reopened.ingest([after, onBoundary, late], window: next, isRefresh: true).inserted == 1 && reopened.importHistory().refreshThrough == later,
              "the next refresh picks up a receipt at the previous upper bound without duplicates")
}
