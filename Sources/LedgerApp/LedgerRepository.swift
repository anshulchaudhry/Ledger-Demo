import Foundation
import LedgerCore

// The demo bundle stays fictional even when opened directly from Finder.
enum AppMode {
    static let demo = Bundle.main.bundleIdentifier == "local.ledger.demo" || CommandLine.arguments.contains("--demo")
}

// All I/O runs off the UI actor. No message or finance fields are logged.
actor LedgerRepository {
    let demo: Bool
    let storeURL: URL
    private let messagesPath: String

    init(demo: Bool) {
        self.demo = demo
        storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(demo ? "LedgerDemo" : "Ledger", isDirectory: true)
            .appendingPathComponent("transactions.sqlite")
        messagesPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    func load() throws -> [TransactionRecord] {
        let store = try TransactionStore(url: storeURL)
        if demo { _ = try store.ingest(FictionalMessages.all) }
        _ = try store.categorizeAutomatically()
        return try store.load()
    }
    func importMessages(window: ImportWindow?) throws -> ImportResult? {
        let store = try TransactionStore(url: storeURL)
        // Freeze the upper bound before opening Messages. Receipts that arrive
        // during this scan remain eligible for the next one.
        let now = Date()
        let scan: ImportWindow?
        if let window {
            scan = window.endingBefore(now)
        } else {
            scan = try store.importHistory().refreshWindow(now: now)
        }
        guard let scan else { return nil }
        let messages = demo ? FictionalMessages.all : try MessagesReader.read(path: messagesPath, window: scan)
        return try store.ingest(messages, window: scan, isRefresh: window == nil)
    }
    func importHistory() throws -> ImportHistory {
        try TransactionStore(url: storeURL).importHistory()
    }
    func save(_ record: TransactionRecord, rememberMerchantCategory: Bool) throws {
        try TransactionStore(url: storeURL).save(record, rememberMerchantCategory: rememberMerchantCategory)
    }
    func merchantRules() throws -> [MerchantCategoryRule] {
        try TransactionStore(url: storeURL).merchantRules()
    }
    func recipientTypeRules() throws -> [RecipientTypeRule] { try TransactionStore(url: storeURL).recipientTypeRules() }
    func recipientGroups() throws -> [RecipientReview.Group] { try TransactionStore(url: storeURL).recipientReviewGroups() }
    func applyRecipientReview(_ plan: RecipientReview.Plan) throws -> Int { try TransactionStore(url: storeURL).applyRecipientReview(plan) }
    func updateRecipientRule(_ rule: RecipientTypeRule, previous: RecipientTypeRule) throws {
        try TransactionStore(url: storeURL).updateRecipientTypeRule(rule, previous: previous)
    }
    func removeRecipientRule(_ rule: RecipientTypeRule) throws { try TransactionStore(url: storeURL).removeRecipientTypeRule(rule) }
    func saveMerchantRule(_ rule: MerchantCategoryRule) throws {
        try TransactionStore(url: storeURL).saveMerchantRule(rule)
    }
    func removeMerchantRule(id: String) throws {
        try TransactionStore(url: storeURL).removeMerchantRule(id: id)
    }
    func categorizeAutomatically() throws -> Int {
        try TransactionStore(url: storeURL).categorizeAutomatically()
    }
    func categorySuggestions() throws -> [CategorySuggestion] {
        try TransactionStore(url: storeURL).categorySuggestions()
    }
    func applyCategorySuggestions(_ suggestions: [CategorySuggestion], rememberMerchants: Bool) throws -> Int {
        try TransactionStore(url: storeURL).applyCategorySuggestions(suggestions, rememberMerchants: rememberMerchants)
    }
    func delete(id: String) throws -> TransactionRecord {
        try TransactionStore(url: storeURL).deleteForUndo(id: id)
    }
    func restore(_ record: TransactionRecord) throws {
        try TransactionStore(url: storeURL).restoreDeleted(record)
    }
    func cardPaymentDuplicates() throws -> [CardPaymentDuplicate] {
        let store = try TransactionStore(url: storeURL)
        let messages = try readSavedSources(windows: store.importHistory().sourceWindows)
        try Task.checkCancellation()
        return try store.cardPaymentDuplicates(messages: messages)
    }
    func linkCardPayment(_ pair: CardPaymentDuplicate, keeping id: String) throws -> [TransactionRecord] {
        let store = try TransactionStore(url: storeURL)
        try store.linkCardPayment(pair, keeping: id)
        return try store.load()
    }
    func unlinkCardPayment(id: String, otherID: String) throws -> [TransactionRecord] {
        let store = try TransactionStore(url: storeURL)
        try store.unlinkCardPayment(id: id, otherID: otherID)
        return try store.load()
    }
    func original(id: String) throws -> Message? {
        let store = try TransactionStore(url: storeURL)
        let windows = try store.importHistory().sourceWindows
        for source in try store.sources(id: id) {
            if let message = try original(source: source, windows: windows) { return message }
        }
        return nil
    }
    func linkedOriginals(id: String) throws -> [Message?] {
        let store = try TransactionStore(url: storeURL)
        let windows = try store.importHistory().sourceWindows
        return try store.linkedCardPaymentSources(id: id).map { try original(source: $0, windows: windows) }
    }
    private func original(source: SourceIdentity, windows: [ImportWindow]) throws -> Message? {
        if demo { return FictionalMessages.all.first { ImportIdentity.source($0) == source } }
        for window in windows {
            try Task.checkCancellation()
            if let message = try MessagesReader.originalMessage(path: messagesPath, source: source, window: window) { return message }
        }
        return nil
    }
    private func readSavedSources(windows: [ImportWindow]) throws -> [Message] {
        if demo { return FictionalMessages.all }
        return try windows.flatMap { window in
            try Task.checkCancellation()
            return try MessagesReader.read(path: messagesPath, window: window)
        }
    }
    func analyzeReviewSources(records: [TransactionRecord]) throws -> ReviewDiagnostics.SourceAnalysis {
        let review = records.filter(\.needsReview)
        guard !review.isEmpty else { return ReviewDiagnostics.SourceAnalysis(records: [], messages: [], sources: [:]) }
        try Task.checkCancellation()
        let store = try TransactionStore(url: storeURL)
        var sources: [String: [SourceIdentity]] = [:]
        for row in review {
            try Task.checkCancellation()
            sources[row.id] = try store.sources(id: row.id)
        }
        let messages: [Message]
        let windows = try store.importHistory().sourceWindows
        do {
            // Explicit report action only. Same bounded, read-only bank-SMS query
            // as manual import; no ingest/save/categorization or source logging.
            messages = try readSavedSources(windows: windows)
        } catch DatabaseError.unavailable { return .init(records: review, failure: .access) }
          catch DatabaseError.unsupportedSchema { return .init(records: review, failure: .schema) }
          catch DatabaseError.queryFailed { return .init(records: review, failure: .read) }
        try Task.checkCancellation()
        return ReviewDiagnostics.SourceAnalysis(records: review, messages: messages, sources: sources, windows: windows)
    }
}

struct SourcePresentation {
    let text: String?
    let explanation: String
    var receivedAt: Date? = nil
    var parsed: Transaction? = nil
    var bank: Bank? = nil

    var receiptLabel: String? {
        receivedAt.map { date in
            let timestamp = date.formatted(TransactionRecord.dateStyle.year().hour().minute().second())
            return "Received \(timestamp) (IST)"
        }
    }
}

@MainActor
final class TransactionsModel: ObservableObject {
    @Published private(set) var transactions: [TransactionRecord] = []
    @Published private(set) var rules: [MerchantCategoryRule] = []
    @Published private(set) var recipientRules: [RecipientTypeRule] = []
    @Published private(set) var recipientGroups: [RecipientReview.Group] = []
    @Published private(set) var categorySuggestions: [CategorySuggestion] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var importHistory: ImportHistory?
    @Published private(set) var deletionHistory: [TransactionRecord] = []
    @Published var error: String?
    let demo: Bool
    private let repository: LedgerRepository

    var lastRefreshLabel: String {
        guard let refreshedAt = importHistory?.lastRefreshAt else { return "No refresh recorded" }
        return "\(refreshedAt.formatted(TransactionRecord.dateStyle.year().hour().minute().second())) (IST)"
    }

    var savedDateRangeLabel: String? {
        let dates = transactions.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let style = TransactionRecord.dateStyle.year()
        let start = first.formatted(style)
        return TransactionRecord.calendar.isDate(first, inSameDayAs: last) ? start : "\(start) – \(last.formatted(style))"
    }

    init(demo: Bool) {
        self.demo = demo
        repository = LedgerRepository(demo: demo)
    }
    func load() async {
        busy = true
        defer { busy = false }
        do {
            transactions = try await repository.load()
            importHistory = try await repository.importHistory()
            try await reloadRules()
        }
        catch { self.error = Self.explain(error) }
    }
    func importMessages(window: ImportWindow? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let result = try await repository.importMessages(window: window) else {
                status = "There are no elapsed receipt dates to scan in this range."
                return
            }
            transactions = try await repository.load()
            importHistory = try await repository.importHistory()
            try await reloadRules()
            status = "\(result.inserted) added · \(result.updated) updated · \(result.excluded) non-transactions excluded · \(result.unparsed) unparsed candidates."
        } catch { self.error = Self.explain(error) }
    }
    func save(_ record: TransactionRecord, rememberMerchantCategory: Bool) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await repository.save(record, rememberMerchantCategory: rememberMerchantCategory)
            transactions = try await repository.load()
            try await reloadRules()
            status = rememberMerchantCategory ? "Correction and merchant category rule saved locally." : "Correction saved locally. Future imports will preserve it."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func saveMerchantRule(_ rule: MerchantCategoryRule) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await repository.saveMerchantRule(rule)
            transactions = try await repository.load()
            try await reloadRules()
            status = "Merchant rule saved. Local categorization refreshed untouched, uncategorized money-out records; transaction review stays separate."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func removeMerchantRule(id: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await repository.removeMerchantRule(id: id)
            try await reloadRules()
            status = "Merchant rule removed. Existing transaction categories are unchanged."
        } catch { self.error = Self.explain(error) }
    }
    func categorizeAutomatically() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let count = try await repository.categorizeAutomatically()
            transactions = try await repository.load()
            try await reloadRules()
            status = "\(count) categories filled locally. Saved edits and assigned categories were kept."
        } catch { self.error = Self.explain(error) }
    }
    func loadCategorySuggestions() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        categorySuggestions = []
        do { categorySuggestions = try await repository.categorySuggestions() }
        catch { self.error = Self.explain(error) }
    }
    func applyCategorySuggestions(_ selected: [CategorySuggestion], rememberMerchants: Bool) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let count = try await repository.applyCategorySuggestions(selected, rememberMerchants: rememberMerchants)
            transactions = try await repository.load()
            try await reloadRules()
            categorySuggestions = []
            status = "\(count) category suggestions saved locally." + (rememberMerchants ? " Merchant rules remembered for future imports." : "")
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    @discardableResult
    func delete(id: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let snapshot = try await repository.delete(id: id)
            deletionHistory.append(snapshot)
            transactions.removeAll { $0.id == id }
            status = "Transaction deleted. Undo is available until Ledger quits."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    @discardableResult
    func undoDeletion() async -> TransactionRecord? {
        guard !busy, let snapshot = deletionHistory.last else { return nil }
        busy = true
        defer { busy = false }
        do {
            try await repository.restore(snapshot)
            deletionHistory.removeLast()
            transactions.append(snapshot)
            transactions.sort { $0.date > $1.date }
            status = "Transaction restored with its saved details and category."
            return snapshot
        } catch { self.error = Self.explain(error); return nil }
    }
    func original(id: String) async -> SourcePresentation {
        do {
            return Self.presentSource(try await repository.original(id: id))
        } catch { return SourcePresentation(text: nil, explanation: Self.explain(error) + " You can still edit this transaction.") }
    }
    func linkedOriginals(id: String) async -> [SourcePresentation] {
        do { return try await repository.linkedOriginals(id: id).map(Self.presentSource) }
        catch { return [SourcePresentation(text: nil, explanation: Self.explain(error))] }
    }
    private static func presentSource(_ message: Message?) -> SourcePresentation {
        SourcePresentation(text: message?.text, explanation: message == nil
            ? "The original message was removed, changed or could not be decoded."
            : "Fetched locally on demand · Full SMS is not saved in Ledger’s database",
            receivedAt: message?.receivedAt, parsed: message.flatMap(Parser.parse),
            bank: message.flatMap { Bank.from(sender: $0.sender) })
    }
    func cardPaymentDuplicates() async throws -> [CardPaymentDuplicate] {
        try await repository.cardPaymentDuplicates()
    }
    func linkCardPayment(_ pair: CardPaymentDuplicate, keeping id: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            transactions = try await repository.linkCardPayment(pair, keeping: id)
            status = "Two SMS receipts linked to one card payment."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func unlinkCardPayment(id: String, otherID: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            transactions = try await repository.unlinkCardPayment(id: id, otherID: otherID)
            status = "Card payment unlinked. Both records are visible again."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func analyzeReviewSources(records: [TransactionRecord]) async throws -> ReviewDiagnostics.SourceAnalysis {
        try await repository.analyzeReviewSources(records: records)
    }
    private func reloadRules() async throws {
        rules = try await repository.merchantRules()
        recipientRules = try await repository.recipientTypeRules()
    }
    func loadRecipientGroups() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        recipientGroups = []
        do { recipientGroups = try await repository.recipientGroups() }
        catch { self.error = Self.explain(error) }
    }
    func applyRecipientReview(_ plan: RecipientReview.Plan) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let count = try await repository.applyRecipientReview(plan)
            transactions = try await repository.load()
            try await reloadRules()
            recipientGroups = try await repository.recipientGroups()
            status = "\(count) \(count == 1 ? "payment" : "payments") confirmed." + (plan.remember ? " Recipient choice remembered for new exact matches from this bank." : " No new recipient rule created.")
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func updateRecipientRule(_ rule: RecipientTypeRule, previous: RecipientTypeRule) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await repository.updateRecipientRule(rule, previous: previous)
            try await reloadRules()
            status = "Recipient rule updated for new imports. Existing payments are unchanged."
            return true
        } catch { self.error = Self.explain(error); return false }
    }
    func removeRecipientRule(_ rule: RecipientTypeRule) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await repository.removeRecipientRule(rule)
            try await reloadRules()
            status = "Recipient rule removed. Existing payments are unchanged."
        } catch { self.error = Self.explain(error) }
    }
    static func explain(_ error: Error) -> String {
        switch error {
        case DatabaseError.unavailable:
            "Messages is unavailable or access was denied. Quit Ledger. In System Settings → Privacy & Security → Full Disk Access, enable the copy of Ledger you use, then reopen it and use Import Messages. After moving from an older development build, remove the old Ledger entry and add the newly signed app once. Ledger only reads Messages; saved transactions remain available without this permission."
        case DatabaseError.unsupportedSchema:
            "This Messages database format is not supported. No records were imported."
        case DatabaseError.queryFailed:
            "Messages could not be read. Try again after Messages finishes syncing."
        case StoreError.staleSuggestions:
            "Records or rules changed while this review was open. Refresh and review them again; nothing from that batch was changed."
        case StoreError.recipientConflict:
            "This recipient has confirmed payments of a different type. Review the selections without remembering, or correct those conflicting payments first. Nothing was changed."
        case StoreError.linkedCardPayment:
            "Unlink the card payment before deleting it or changing its payment type."
        case StoreError.unsupportedVersion:
            "This Ledger database was created by a newer version. Use that version to open it."
        default:
            "Ledger could not read or save its local database. Check available disk space and access to Library/Application Support/Ledger (LedgerDemo in demo mode), then try again."
        }
    }
}
