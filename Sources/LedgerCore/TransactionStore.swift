import Foundation
import SQLite3

package enum StoreError: Error { case unavailable, unsupportedVersion, operationFailed, invalidRecord, staleSuggestions, recipientConflict, linkedCardPayment }

package struct ImportResult: Sendable {
    package var candidates = 0
    package var inserted = 0
    package var existing = 0
    package var updated = 0
    package var excluded = 0
    package var unparsed = 0
}

// Owns only Ledger's database. Messages access is kept in MessagesReader.
// Synchronous and confined to one caller; the app uses a repository actor.
package final class TransactionStore {
    private var database: OpaquePointer?
    private enum Value { case text(String), number(Int64), real(Double), null }

    package init(url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.unavailable
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw StoreError.unavailable
        }
        database = handle
        do {
            sqlite3_busy_timeout(database, 3000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            // Read the version while holding the migration lock so two app
            // windows cannot both attempt the same upgrade.
            try atomic {
                let version = try statement("PRAGMA user_version")
                let status = sqlite3_step(version)
                let current = sqlite3_column_int(version, 0)
                sqlite3_finalize(version)
                guard status == SQLITE_ROW else { throw StoreError.operationFailed }
                guard (0...8).contains(current) else { throw StoreError.unsupportedVersion }
                if current == 0 {
                    try execute("""
                        CREATE TABLE transactions (
                            id TEXT PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0,
                            date REAL, merchant TEXT, bank TEXT, amount_paise INTEGER,
                            direction TEXT, type TEXT, date_from_sms INTEGER, edited INTEGER NOT NULL DEFAULT 0,
                            category TEXT, excluded INTEGER NOT NULL DEFAULT 0
                        )
                        """)
                    try execute("CREATE TABLE sources (source_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id), guid TEXT)")
                    try execute("CREATE TABLE duplicate_keys (duplicate_key TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id))")
                    try execute("CREATE INDEX sources_transaction ON sources(transaction_id)")
                } else if current == 1 {
                    try execute("ALTER TABLE transactions ADD COLUMN category TEXT")
                    // Never change an existing financial field, edit flag or
                    // source identity. Deleted rows retain no category data.
                    try execute("UPDATE transactions SET category='uncategorized' WHERE deleted=0")
                }
                if current == 1 || current == 2 {
                    try execute("ALTER TABLE transactions ADD COLUMN excluded INTEGER NOT NULL DEFAULT 0")
                }
                if current < 4 {
                    try execute("CREATE TABLE merchant_category_rules (merchant_key TEXT PRIMARY KEY, merchant TEXT NOT NULL, category TEXT NOT NULL)")
                    try execute("PRAGMA user_version = 4")
                }
                if current < 5 {
                    try execute("ALTER TABLE transactions ADD COLUMN type_rule_key TEXT")
                    try execute("CREATE TABLE recipient_type_rules (recipient_key TEXT PRIMARY KEY, recipient TEXT NOT NULL, bank TEXT NOT NULL, type TEXT NOT NULL, category TEXT)")
                }
                if current < 6 {
                    try execute("""
                        CREATE TABLE card_payment_links (
                            retained_id TEXT PRIMARY KEY NOT NULL REFERENCES transactions(id),
                            other_id TEXT NOT NULL UNIQUE REFERENCES transactions(id),
                            retained_source TEXT NOT NULL REFERENCES sources(source_key),
                            other_source TEXT NOT NULL REFERENCES sources(source_key),
                            CHECK(retained_id <> other_id)
                        )
                        """)
                }
                if current < 7 {
                    try execute("""
                        CREATE TABLE import_scans (
                            start REAL NOT NULL, end_exclusive REAL NOT NULL, completed_at REAL NOT NULL,
                            candidates INTEGER NOT NULL, inserted INTEGER NOT NULL, already_saved INTEGER NOT NULL,
                            updated INTEGER NOT NULL, excluded INTEGER NOT NULL, unparsed INTEGER NOT NULL,
                            PRIMARY KEY(start,end_exclusive)
                        )
                        """)
                }
                if current < 8 {
                    try execute("ALTER TABLE import_scans ADD COLUMN refresh_completed_at REAL")
                    try execute("PRAGMA user_version = 8")
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    package func load() throws -> [TransactionRecord] {
        let query = try statement("""
            SELECT id,date,merchant,bank,amount_paise,direction,type,date_from_sms,edited,category,type_rule_key,link.other_id
            FROM transactions LEFT JOIN card_payment_links AS link ON link.retained_id=id
            WHERE deleted=0 AND excluded=0 AND id NOT IN (SELECT other_id FROM card_payment_links)
            ORDER BY date DESC,id
            """)
        defer { sqlite3_finalize(query) }
        var records: [TransactionRecord] = []
        while try next(query) {
            guard let bank = Bank(rawValue: text(query, 3)),
                  let direction = Direction(rawValue: text(query, 5)),
                  let type = TransactionType(rawValue: text(query, 6)),
                  let category = SpendingCategory(rawValue: text(query, 9)) else { throw StoreError.invalidRecord }
            records.append(TransactionRecord(id: text(query, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(query, 1)),
                merchant: text(query, 2), bank: bank, amountPaise: sqlite3_column_int64(query, 4),
                direction: direction, type: type, dateFromSMS: sqlite3_column_int(query, 7) != 0,
                manuallyEdited: sqlite3_column_int(query, 8) != 0, category: category,
                recipientTypeRuleKey: sqlite3_column_type(query, 10) == SQLITE_NULL ? nil : text(query, 10),
                linkedCardPaymentID: sqlite3_column_type(query, 11) == SQLITE_NULL ? nil : text(query, 11)))
        }
        return records
    }

    package func ingest(_ messages: [Message], window: ImportWindow? = nil, isRefresh: Bool = false) throws -> ImportResult {
        var result = ImportResult()
        let receiptWindow = window ?? .legacy
        let candidates = messages.filter {
            receiptWindow.contains($0.receivedAt) &&
            !$0.isFromMe && $0.service.uppercased() == "SMS" && Bank.from(sender: $0.sender) != nil
        }.map { (message: $0, source: ImportIdentity.source($0), transaction: Parser.parse($0)) }
        let availableSources = Set(candidates.map { $0.source.key })
        let parsedSources = Set(candidates.compactMap { $0.transaction == nil ? nil : $0.source.key })
        // A narrow scan cannot arbitrate between deliveries it did not see.
        let observedSources = window == nil ? nil : availableSources
        var reconciled = Set<String>()
        var pendingExclusions: [(source: SourceIdentity, id: String)] = []
        result.candidates = candidates.count
        try atomic {
            let linked = try linkedCardPaymentIDs()
            let pipeline = CategorizationPipeline(rules: try merchantRules())
            let typeRules = try recipientTypeRules()
            var known = RecipientReview.knownTypes(records: try load())
            // Look at every explicit type in the batch before using a rule, so
            // source ordering cannot let an automatic choice precede a conflict.
            for candidate in candidates {
                if let transaction = candidate.transaction, transaction.direction == .debit,
                   transaction.type != .uncertain, let merchant = transaction.merchant,
                   let key = RecipientTypeRule.key(recipient: merchant, bank: transaction.bank) {
                    let sourceID = try find("SELECT transaction_id FROM sources WHERE source_key=?", candidate.source.key)
                    let duplicateID = try find("SELECT transaction_id FROM duplicate_keys WHERE duplicate_key=?",
                        ImportIdentity.duplicate(candidate.message, transaction: transaction))
                    if let id = sourceID ?? duplicateID, try sourceDecisionProtected(id: id) { continue }
                    known[key, default: []].insert(transaction.type)
                }
            }
            for candidate in candidates {
                let source = candidate.source
                let sourceID = try find("SELECT transaction_id FROM sources WHERE source_key = ?", source.key)
                guard let transaction = candidate.transaction else {
                    result.unparsed += 1
                    // Reconcile only explicit nontransaction rules. Missing text,
                    // unsupported wording and absent source messages never hide rows.
                    if let id = sourceID, !linked.contains(id), Parser.isKnownNonTransaction(candidate.message) {
                        pendingExclusions.append((source, id))
                    }
                    continue
                }
                let duplicate = ImportIdentity.duplicate(candidate.message, transaction: transaction)
                let duplicateID = try find("SELECT transaction_id FROM duplicate_keys WHERE duplicate_key = ?", duplicate)
                let id = sourceID ?? duplicateID ?? UUID().uuidString
                if sourceID == nil && duplicateID == nil {
                    let rule = typeRules.first { rule in
                        transaction.direction == .debit && transaction.type == .uncertain && RecipientTypeRule.allowsAutomatic(candidate.message) &&
                            transaction.merchant.flatMap { RecipientTypeRule.key(recipient: $0, bank: transaction.bank) } == rule.id &&
                            (known[rule.id] ?? []).allSatisfy { $0 == rule.type }
                    }
                    var category = categoryFor(transaction, pipeline: pipeline)
                    if let rule, rule.type == .expense, let rememberedCategory = rule.category,
                       transaction.merchant.flatMap({ pipeline.decision(merchant: $0, direction: .debit, type: .expense) })?.source != .savedRule {
                        category = rememberedCategory
                    }
                    try execute("INSERT INTO transactions(id,date,merchant,bank,amount_paise,direction,type,date_from_sms,category,type_rule_key) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                        .text(id), .real(transaction.transactionAt.timeIntervalSince1970),
                        .text(transaction.merchant ?? "Recipient not identified"), .text(transaction.bank.rawValue),
                        .number(transaction.amountPaise), .text(transaction.direction.rawValue), .text((rule?.type ?? transaction.type).rawValue),
                        .number(transaction.dateFromSMS ? 1 : 0), .text(category.rawValue), rule.map { .text($0.id) } ?? .null
                    ])
                    result.inserted += 1
                } else {
                    result.existing += 1
                }
                try execute("INSERT INTO sources(source_key,transaction_id,guid) VALUES (?,?,?) ON CONFLICT(source_key) DO NOTHING",
                            [.text(source.key), .text(id), source.guid.map(Value.text) ?? .null])
                try execute("INSERT INTO duplicate_keys(duplicate_key,transaction_id) VALUES (?,?) ON CONFLICT(duplicate_key) DO NOTHING",
                            [.text(duplicate), .text(id)])
                if sourceID != nil || duplicateID != nil,
                   !linked.contains(id),
                   try isRefreshSource(source, id: id, available: parsedSources, observed: observedSources),
                   reconciled.insert(id).inserted, try refresh(transaction, id: id, pipeline: pipeline, allowRememberedType: RecipientTypeRule.allowsAutomatic(candidate.message)) {
                    result.updated += 1
                }
            }
            // A valid alternate delivery wins over a reminder alias. Evaluate
            // exclusions only after all parsed source aliases have been linked.
            for item in pendingExclusions {
                guard try !sources(id: item.id).contains(where: { parsedSources.contains($0.key) }),
                      try isRefreshSource(item.source, id: item.id, available: availableSources, observed: observedSources),
                      reconciled.insert(item.id).inserted else { continue }
                try execute("UPDATE transactions SET excluded=1 WHERE id=? AND edited=0 AND deleted=0 AND excluded=0", [.text(item.id)])
                result.excluded += Int(sqlite3_changes(database))
            }
            if let window { try recordImport(window, result: result, isRefresh: isRefresh) }
        }
        return result
    }

    // Refresh the first available known delivery in insertion order. This keeps
    // repeated deliveries from changing the row back and forth during an import.
    private func isRefreshSource(_ source: SourceIdentity, id: String, available: Set<String>, observed: Set<String>?) throws -> Bool {
        let linked = try sources(id: id)
        if let observed, !linked.allSatisfy({ observed.contains($0.key) }) { return false }
        return linked.first(where: { available.contains($0.key) })?.key == source.key
    }

    private func recordImport(_ window: ImportWindow, result: ImportResult, isRefresh: Bool) throws {
        let completedAt = Date().timeIntervalSince1970
        try execute("""
            INSERT INTO import_scans (start,end_exclusive,completed_at,candidates,inserted,already_saved,updated,excluded,unparsed,refresh_completed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(start,end_exclusive) DO UPDATE SET completed_at=excluded.completed_at,
              candidates=excluded.candidates, inserted=excluded.inserted, already_saved=excluded.already_saved,
              updated=excluded.updated, excluded=excluded.excluded, unparsed=excluded.unparsed,
              refresh_completed_at=COALESCE(excluded.refresh_completed_at,import_scans.refresh_completed_at)
            """, [.real(window.start.timeIntervalSince1970), .real(window.endExclusive.timeIntervalSince1970),
                    .real(completedAt), .number(Int64(result.candidates)), .number(Int64(result.inserted)),
                    .number(Int64(result.existing)), .number(Int64(result.updated)), .number(Int64(result.excluded)),
                    .number(Int64(result.unparsed)), isRefresh ? .real(completedAt) : .null])
    }

    package func importHistory() throws -> ImportHistory {
        let query = try statement("SELECT start,end_exclusive,completed_at,candidates,inserted,already_saved,updated,excluded,unparsed,refresh_completed_at FROM import_scans ORDER BY completed_at DESC,rowid DESC")
        defer { sqlite3_finalize(query) }
        var windows: [ImportWindow] = []
        var elapsedWindows: [ImportWindow] = []
        var lastScan: ImportHistory.Scan?
        var lastRefreshAt: Date?
        while try next(query) {
            let window = ImportWindow(start: Date(timeIntervalSince1970: sqlite3_column_double(query, 0)),
                                      endExclusive: Date(timeIntervalSince1970: sqlite3_column_double(query, 1)))
            let completedAt = Date(timeIntervalSince1970: sqlite3_column_double(query, 2))
            windows.append(window)
            // Older manual scans recorded the end of the selected day even
            // when it was still in progress at the time of the scan.
            if let elapsed = window.endingBefore(completedAt) { elapsedWindows.append(elapsed) }
            if sqlite3_column_type(query, 9) != SQLITE_NULL {
                let refreshed = Date(timeIntervalSince1970: sqlite3_column_double(query, 9))
                lastRefreshAt = max(lastRefreshAt ?? refreshed, refreshed)
            }
            if lastScan == nil {
                let result = ImportResult(candidates: Int(sqlite3_column_int64(query, 3)), inserted: Int(sqlite3_column_int64(query, 4)),
                    existing: Int(sqlite3_column_int64(query, 5)), updated: Int(sqlite3_column_int64(query, 6)),
                    excluded: Int(sqlite3_column_int64(query, 7)), unparsed: Int(sqlite3_column_int64(query, 8)))
                lastScan = .init(window: window, completedAt: completedAt, result: result)
            }
        }
        // A standalone manual backfill may sit beyond a gap. Only continuous
        // recorded coverage from August 1 can advance the refresh boundary.
        let scannedWindows = ImportWindow.merged(elapsedWindows)
        let refreshThrough = scannedWindows.first { $0.contains(ImportWindow.defaultStart) }?.endExclusive
        return ImportHistory(windows: ImportWindow.merged(windows), scannedWindows: scannedWindows, lastScan: lastScan,
                             lastRefreshAt: lastRefreshAt, refreshThrough: refreshThrough)
    }

    private func sourceDecisionProtected(id: String) throws -> Bool {
        let query = try statement("SELECT deleted,edited FROM transactions WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(query) }
        return try next(query) && (sqlite3_column_int(query, 0) != 0 || sqlite3_column_int(query, 1) != 0)
    }

    private func refresh(_ transaction: Transaction, id: String, pipeline: CategorizationPipeline, allowRememberedType: Bool) throws -> Bool {
        var type = transaction.type
        var ruleKey: String?
        let previous = try statement("SELECT type,type_rule_key FROM transactions WHERE id=? AND edited=0 AND deleted=0", [.text(id)])
        defer { sqlite3_finalize(previous) }
        if try next(previous), sqlite3_column_type(previous, 1) != SQLITE_NULL, allowRememberedType,
           transaction.direction == .debit, transaction.type == .uncertain,
           let merchant = transaction.merchant,
           RecipientTypeRule.key(recipient: merchant, bank: transaction.bank) == text(previous, 1),
           let savedType = TransactionType(rawValue: text(previous, 0)), RecipientTypeRule.allowedTypes.contains(savedType) {
            type = savedType; ruleKey = text(previous, 1)
        }
        let values: [Value] = [
            .real(transaction.transactionAt.timeIntervalSince1970),
            .text(transaction.merchant ?? "Recipient not identified"), .text(transaction.bank.rawValue),
            .number(transaction.amountPaise), .text(transaction.direction.rawValue), .text(type.rawValue),
            .number(transaction.dateFromSMS ? 1 : 0), ruleKey.map(Value.text) ?? .null
        ]
        try execute("""
            UPDATE transactions SET date=?,merchant=?,bank=?,amount_paise=?,direction=?,type=?,date_from_sms=?,type_rule_key=?,excluded=0
            WHERE id=? AND edited=0 AND deleted=0
              AND (date IS NOT ? OR merchant IS NOT ? OR bank IS NOT ? OR amount_paise IS NOT ?
                   OR direction IS NOT ? OR type IS NOT ? OR date_from_sms IS NOT ? OR type_rule_key IS NOT ? OR excluded<>0)
            """, values + [.text(id)] + values)
        let refreshed = sqlite3_changes(database) == 1
        let category = categoryFor(transaction, pipeline: pipeline, keepsRecipientCategory: ruleKey != nil)
        var categorized = false
        if category != .uncategorized {
            try execute("UPDATE transactions SET category=? WHERE id=? AND edited=0 AND deleted=0 AND excluded=0 AND category='uncategorized' AND type IN ('expense','uncertain') AND direction='debit'", [.text(category.rawValue), .text(id)])
            categorized = sqlite3_changes(database) == 1
        }
        return refreshed || categorized
    }

    private func categoryFor(_ transaction: Transaction, pipeline: CategorizationPipeline, keepsRecipientCategory: Bool = false) -> SpendingCategory {
        guard let merchant = transaction.merchant,
              let decision = pipeline.decision(merchant: merchant, direction: transaction.direction, type: transaction.type),
              decision.automatic, !keepsRecipientCategory || decision.source == .savedRule else { return .uncategorized }
        return decision.category
    }

    // Runs from saved records, without reading Messages. Existing categories and
    // manual corrections stay intact; automatic values remain parser-refreshable.
    package func categorizeAutomatically() throws -> Int {
        var count = 0
        try atomic {
            let pipeline = CategorizationPipeline(rules: try merchantRules())
            for row in try load() where row.category == .uncategorized && !row.manuallyEdited && row.valid {
                // Recipient rules set the category at import. Keep a Miscellaneous
                // choice even after rule removal, while honoring explicit merchant rules.
                guard let decision = pipeline.decision(merchant: row.merchant, direction: row.direction, type: row.type),
                      decision.automatic, decision.category != row.category,
                      row.recipientTypeRuleKey == nil || decision.source == .savedRule else { continue }
                try execute("UPDATE transactions SET category=? WHERE id=? AND edited=0 AND deleted=0 AND excluded=0 AND category='uncategorized'", [.text(decision.category.rawValue), .text(row.id)])
                count += Int(sqlite3_changes(database))
            }
        }
        return count
    }

    package func save(_ record: TransactionRecord, rememberMerchantCategory: Bool = false) throws {
        guard record.valid else { throw StoreError.invalidRecord }
        let rule = rememberMerchantCategory ? MerchantCategoryRule(merchant: record.merchant, category: record.category) : nil
        if rememberMerchantCategory && (!record.isConfirmedExpense || rule == nil) { throw StoreError.invalidRecord }
        try atomic {
            if try linkedCardPaymentIDs().contains(record.id) {
                guard record.type == .cardPayment,
                      try find("SELECT retained_id FROM card_payment_links WHERE retained_id=?", record.id) != nil
                else { throw StoreError.linkedCardPayment }
            }
            try execute("UPDATE transactions SET date=?,merchant=?,bank=?,amount_paise=?,direction=?,type=?,date_from_sms=?,category=?,edited=1,excluded=0,type_rule_key=NULL WHERE id=? AND deleted=0", [
                .real(record.date.timeIntervalSince1970), .text(record.merchant.trimmingCharacters(in: .whitespacesAndNewlines)),
                .text(record.bank.rawValue), .number(record.amountPaise), .text(record.direction.rawValue),
                .text(record.type.rawValue), .number(record.dateFromSMS ? 1 : 0), .text(record.category.rawValue), .text(record.id)
            ])
            guard sqlite3_changes(database) == 1 else { throw StoreError.invalidRecord }
            if let rule { try saveMerchantRule(rule) }
        }
    }

    package func merchantRules() throws -> [MerchantCategoryRule] {
        let query = try statement("SELECT merchant_key,merchant,category FROM merchant_category_rules ORDER BY merchant COLLATE NOCASE")
        defer { sqlite3_finalize(query) }
        var rules: [MerchantCategoryRule] = []
        while try next(query) {
            guard let category = SpendingCategory(rawValue: text(query, 2)),
                  let rule = MerchantCategoryRule(merchant: text(query, 1), category: category),
                  rule.id == text(query, 0) else { throw StoreError.invalidRecord }
            rules.append(rule)
        }
        return rules
    }

    package func categorySuggestions() throws -> [CategorySuggestion] {
        let pipeline = CategorizationPipeline(rules: try merchantRules())
        return try load().compactMap { record in
            guard record.valid, record.isConfirmedExpense, record.category == .uncategorized,
                  let decision = pipeline.decision(merchant: record.merchant, direction: record.direction, type: record.type),
                  decision.category != record.category else { return nil }
            return CategorySuggestion(transaction: record, category: decision.category, source: decision.source)
        }
    }

    // Explicitly approved batch: write categories only, with full snapshot checks.
    // Saving a rule is a separate opt-in; no source access or type inference.
    package func applyCategorySuggestions(_ suggestions: [CategorySuggestion], rememberMerchants: Bool = false) throws -> Int {
        guard !suggestions.isEmpty else { return 0 }
        guard Set(suggestions.map(\.id)).count == suggestions.count else { throw StoreError.invalidRecord }
        try atomic {
            let fresh = Dictionary(uniqueKeysWithValues: try categorySuggestions().map { ($0.id, $0) })
            guard suggestions.allSatisfy({ fresh[$0.id] == $0 }) else { throw StoreError.staleSuggestions }
            for suggestion in suggestions {
                try execute("UPDATE transactions SET category=?,edited=1,type_rule_key=NULL WHERE id=? AND category='uncategorized' AND deleted=0 AND excluded=0 AND type='expense' AND direction='debit'", [.text(suggestion.category.rawValue), .text(suggestion.id)])
                guard sqlite3_changes(database) == 1 else { throw StoreError.staleSuggestions }
                if rememberMerchants {
                    guard let rule = MerchantCategoryRule(merchant: suggestion.transaction.merchant, category: suggestion.category) else { throw StoreError.invalidRecord }
                    try saveMerchantRule(rule)
                }
            }
        }
        return suggestions.count
    }

    package func saveMerchantRule(_ rule: MerchantCategoryRule) throws {
        guard let validated = MerchantCategoryRule(merchant: rule.merchant, category: rule.category), validated.id == rule.id else { throw StoreError.invalidRecord }
        try execute("INSERT INTO merchant_category_rules(merchant_key,merchant,category) VALUES (?,?,?) ON CONFLICT(merchant_key) DO UPDATE SET merchant=excluded.merchant,category=excluded.category", [.text(rule.id), .text(rule.merchant), .text(rule.category.rawValue)])
    }

    package func removeMerchantRule(id: String) throws {
        try execute("DELETE FROM merchant_category_rules WHERE merchant_key=?", [.text(id)])
    }

    package func recipientTypeRules() throws -> [RecipientTypeRule] {
        let query = try statement("SELECT recipient_key,recipient,bank,type,category FROM recipient_type_rules ORDER BY bank,recipient COLLATE NOCASE")
        defer { sqlite3_finalize(query) }
        var result: [RecipientTypeRule] = []
        while try next(query) {
            let category: SpendingCategory?
            if sqlite3_column_type(query, 4) == SQLITE_NULL { category = nil }
            else {
                guard let value = SpendingCategory(rawValue: text(query, 4)) else { throw StoreError.invalidRecord }
                category = value
            }
            guard let bank = Bank(rawValue: text(query, 2)), let type = TransactionType(rawValue: text(query, 3)),
                  let rule = RecipientTypeRule(recipient: text(query, 1), bank: bank, type: type, category: category),
                  rule.id == text(query, 0) else { throw StoreError.invalidRecord }
            result.append(rule)
        }
        return result
    }

    package func recipientReviewGroups() throws -> [RecipientReview.Group] {
        RecipientReview.groups(records: try load(), rules: try recipientTypeRules())
    }

    // Explicit selected-row confirmation and optional future learning commit
    // together, after rechecking records, group membership, conflicts and rule.
    package func applyRecipientReview(_ plan: RecipientReview.Plan) throws -> Int {
        guard !plan.selectedIDs.isEmpty, plan.selectedIDs.isSubset(of: Set(plan.group.records.map(\.id))),
              plan.amountPaise != nil, RecipientTypeRule.allowedTypes.contains(plan.type),
              plan.category == nil || (plan.type == .expense && plan.category != .incomeSalary),
              plan.proposed.allSatisfy({ $0.valid && !$0.needsReview }) else { throw StoreError.invalidRecord }
        try atomic {
            guard try recipientReviewGroups().first(where: { $0.id == plan.group.id }) == plan.group else { throw StoreError.staleSuggestions }
            if plan.remember && !plan.group.canRemember(plan.type) { throw StoreError.recipientConflict }
            for row in plan.proposed {
                try execute("UPDATE transactions SET type=?,category=?,edited=1,type_rule_key=NULL WHERE id=? AND deleted=0 AND excluded=0 AND direction='debit' AND type='uncertain'",
                            [.text(row.type.rawValue), .text(row.category.rawValue), .text(row.id)])
                guard sqlite3_changes(database) == 1 else { throw StoreError.staleSuggestions }
            }
            if plan.remember {
                guard let rule = RecipientTypeRule(recipient: plan.group.recipient, bank: plan.group.bank, type: plan.type, category: plan.category) else { throw StoreError.invalidRecord }
                try writeRecipientTypeRule(rule)
            }
        }
        return plan.selectedIDs.count
    }

    private func writeRecipientTypeRule(_ rule: RecipientTypeRule) throws {
        guard let valid = RecipientTypeRule(recipient: rule.recipient, bank: rule.bank, type: rule.type, category: rule.category), valid == rule else { throw StoreError.invalidRecord }
        try execute("INSERT INTO recipient_type_rules(recipient_key,recipient,bank,type,category) VALUES (?,?,?,?,?) ON CONFLICT(recipient_key) DO UPDATE SET recipient=excluded.recipient,bank=excluded.bank,type=excluded.type,category=excluded.category",
            [.text(rule.id), .text(rule.recipient), .text(rule.bank.rawValue), .text(rule.type.rawValue), rule.category.map { .text($0.rawValue) } ?? .null])
    }

    package func updateRecipientTypeRule(_ rule: RecipientTypeRule, previous: RecipientTypeRule) throws {
        guard rule.id == previous.id else { throw StoreError.invalidRecord }
        try atomic {
            guard try recipientTypeRules().first(where: { $0.id == previous.id }) == previous else { throw StoreError.staleSuggestions }
            let known = RecipientReview.knownTypes(records: try load())[rule.id] ?? []
            guard known.allSatisfy({ $0 == rule.type }) else { throw StoreError.recipientConflict }
            try writeRecipientTypeRule(rule)
        }
    }

    package func removeRecipientTypeRule(_ rule: RecipientTypeRule) throws {
        try atomic {
            guard try recipientTypeRules().first(where: { $0.id == rule.id }) == rule else { throw StoreError.staleSuggestions }
            try execute("DELETE FROM recipient_type_rules WHERE recipient_key=?", [.text(rule.id)])
        }
    }

    package func delete(id: String) throws {
        // Scrub the finance fields; retain just identities that suppress resurrection.
        try execute("""
            UPDATE transactions SET deleted=1,date=NULL,merchant=NULL,bank=NULL,amount_paise=NULL,direction=NULL,type=NULL,date_from_sms=NULL,category=NULL,type_rule_key=NULL,edited=0,excluded=0
            WHERE id=? AND deleted=0 AND id NOT IN (SELECT retained_id FROM card_payment_links UNION SELECT other_id FROM card_payment_links)
            """, [.text(id)])
        guard sqlite3_changes(database) == 1 else {
            if try linkedCardPaymentIDs().contains(id) { throw StoreError.linkedCardPayment }
            throw StoreError.invalidRecord
        }
    }

    // Snapshot lives only in the app's session Undo stack, never in a trash table.
    // Capture and scrub atomically so failed deletions never create an Undo item.
    package func deleteForUndo(id: String) throws -> TransactionRecord {
        var snapshot: TransactionRecord?
        try atomic {
            guard let record = try load().first(where: { $0.id == id }) else { throw StoreError.invalidRecord }
            try delete(id: id)
            snapshot = record
        }
        return snapshot!
    }

    // Explicit Undo restores fields on the SAME tombstone. Identity/duplicate
    // rows (including aliases learned while deleted) are never removed/rebuilt.
    package func restoreDeleted(_ record: TransactionRecord) throws {
        guard record.valid else { throw StoreError.invalidRecord }
        try atomic {
            try execute("""
                UPDATE transactions SET deleted=0,date=?,merchant=?,bank=?,amount_paise=?,direction=?,type=?,date_from_sms=?,category=?,edited=?,type_rule_key=?,excluded=0
                WHERE id=? AND deleted=1
                """, [.real(record.date.timeIntervalSince1970), .text(record.merchant), .text(record.bank.rawValue),
                      .number(record.amountPaise), .text(record.direction.rawValue), .text(record.type.rawValue),
                      .number(record.dateFromSMS ? 1 : 0), .text(record.category.rawValue),
                      .number(record.manuallyEdited ? 1 : 0), record.recipientTypeRuleKey.map(Value.text) ?? .null, .text(record.id)])
            guard sqlite3_changes(database) == 1 else { throw StoreError.invalidRecord }
        }
    }

    package func sources(id: String) throws -> [SourceIdentity] {
        let query = try statement("SELECT source_key,guid FROM sources WHERE transaction_id=? ORDER BY ROWID", [.text(id)])
        defer { sqlite3_finalize(query) }
        var values: [SourceIdentity] = []
        while try next(query) {
            values.append(SourceIdentity(key: text(query, 0), guid: sqlite3_column_type(query, 1) == SQLITE_NULL ? nil : text(query, 1)))
        }
        return values
    }

    package func cardPaymentDuplicates(messages: [Message]) throws -> [CardPaymentDuplicate] {
        let records = Dictionary(uniqueKeysWithValues: try load().filter {
            $0.type == .cardPayment && $0.linkedCardPaymentID == nil
        }.map { ($0.id, $0) })
        guard !records.isEmpty else { return [] }
        let query = try statement("SELECT source_key,transaction_id FROM sources")
        defer { sqlite3_finalize(query) }
        var bySource: [String: TransactionRecord] = [:]
        while try next(query) { bySource[text(query, 0)] = records[text(query, 1)] }
        return CardPaymentDuplicate.suggestions(messages: messages, recordsBySource: bySource)
    }

    package func linkCardPayment(_ pair: CardPaymentDuplicate, keeping id: String) throws {
        let retained = id == pair.funding.record.id ? pair.funding : pair.issuer
        let other = id == pair.funding.record.id ? pair.issuer : pair.funding
        guard retained.record.id == id, id != other.record.id else { throw StoreError.invalidRecord }
        try atomic {
            let rows = try load()
            for receipt in [retained, other] {
                guard receipt.record.linkedCardPaymentID == nil,
                      rows.first(where: { $0.id == receipt.record.id }) == receipt.record,
                      try sources(id: receipt.record.id).contains(receipt.source) else { throw StoreError.staleSuggestions }
            }
            try execute("INSERT INTO card_payment_links(retained_id,other_id,retained_source,other_source) VALUES (?,?,?,?)",
                        [.text(id), .text(other.record.id), .text(retained.source.key), .text(other.source.key)])
        }
    }

    package func unlinkCardPayment(id: String, otherID: String) throws {
        try execute("DELETE FROM card_payment_links WHERE retained_id=? AND other_id=?", [.text(id), .text(otherID)])
        guard sqlite3_changes(database) == 1 else { throw StoreError.staleSuggestions }
    }

    package func linkedCardPaymentSources(id: String) throws -> [SourceIdentity] {
        let query = try statement("""
            SELECT source_key,guid FROM card_payment_links JOIN sources ON source_key IN (retained_source,other_source)
            WHERE retained_id=? ORDER BY CASE WHEN source_key=retained_source THEN 0 ELSE 1 END
            """, [.text(id)])
        defer { sqlite3_finalize(query) }
        var values: [SourceIdentity] = []
        while try next(query) {
            values.append(SourceIdentity(key: text(query, 0), guid: sqlite3_column_type(query, 1) == SQLITE_NULL ? nil : text(query, 1)))
        }
        return values
    }

    private func linkedCardPaymentIDs() throws -> Set<String> {
        let query = try statement("SELECT retained_id FROM card_payment_links UNION SELECT other_id FROM card_payment_links")
        defer { sqlite3_finalize(query) }
        var ids = Set<String>()
        while try next(query) { ids.insert(text(query, 0)) }
        return ids
    }

    private func find(_ sql: String, _ key: String) throws -> String? {
        let query = try statement(sql, [.text(key)])
        defer { sqlite3_finalize(query) }
        return try next(query) ? text(query, 0) : nil
    }
    private func text(_ query: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(query, column).map { String(cString: $0) } ?? ""
    }
    private func next(_ query: OpaquePointer) throws -> Bool {
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.operationFailed
        }
    }
    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
            sqlite3_finalize(query)
            throw StoreError.operationFailed
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let value): status = sqlite3_bind_text(query, index, value, -1, transient)
            case .number(let value): status = sqlite3_bind_int64(query, index, value)
            case .real(let value): status = sqlite3_bind_double(query, index, value)
            case .null: status = sqlite3_bind_null(query, index)
            }
            guard status == SQLITE_OK else { sqlite3_finalize(query); throw StoreError.operationFailed }
        }
        return query
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        while try next(query) { }
    }
    private func atomic(_ action: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try action()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
