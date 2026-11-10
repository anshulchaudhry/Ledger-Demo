import Foundation

func reviewDiagnosticsChecks() throws {
    func row(_ id: String, _ direction: Direction, _ type: TransactionType,
             _ bank: Bank = .axis, _ category: SpendingCategory = .uncategorized) -> TransactionRecord {
        TransactionRecord(id: id, date: Importer.start, merchant: "PRIVATE_NAME_SENTINEL", bank: bank,
            amountPaise: 987654321, direction: direction, type: type, dateFromSMS: true,
            manuallyEdited: false, category: category)
    }
    var edited = row("edited-private-id", .debit, .uncertain, .idfc, .groceries)
    edited.manuallyEdited = true
    let records = [
        row("expense", .debit, .expense), row("transfer", .credit, .transfer),
        row("card", .debit, .cardPayment), row("refund", .credit, .refund),
        row("incoming", .credit, .incomingPayment), row("salary", .credit, .incomingPayment, .axis, .incomeSalary),
        row("direction", .uncertain, .uncertain, .icici),
        row("known-type-unknown-direction", .uncertain, .expense, .icici),
        row("out-type", .debit, .uncertain, .axis), edited,
        row("in-type", .credit, .uncertain, .idfc),
        row("conflicting-expense", .credit, .expense, .axis),
        row("conflicting-income", .debit, .expense, .icici, .incomeSalary),
    ]
    let report = ReviewDiagnostics(records: records)
    try check(report.total == 7 && report.categorized == 2 && report.savedCorrections == 1,
              "diagnostic review counts do not confuse categories with confirmation")
    try check(report.reasons.first { $0.reason == .direction }?.count == 2 &&
              report.reasons.first { $0.reason == .moneyOutType }?.count == 2 &&
              report.reasons.first { $0.reason == .moneyInType }?.count == 1 &&
              report.reasons.first { $0.reason == .conflictingDetails }?.count == 2,
              "diagnostics distinguish direction, both payment directions and conflicting fields")
    try check(report.reasons.reduce(0) { $0 + $1.count } == report.total &&
              Set(report.reasons.flatMap(\.transactionIDs)).count == report.total &&
              report.banks.reduce(0) { $0 + $1.count } == report.total,
              "review reason groups and bank groups each partition exactly")
    for group in report.reasons + report.banks {
        try check(Set(records.filter(group.includes).map(\.id)) == group.transactionIDs,
                  "diagnostic drill-through matches exact review IDs")
    }
    let outGroup = report.reasons.first { $0.reason == .moneyOutType }!
    var resolved = records.first { $0.id == "out-type" }!
    resolved.type = .expense
    try check(!outGroup.includes(resolved) && resolved.isConfirmedExpense,
              "resolved row leaves an open diagnostic scope")
    resolved.direction = .uncertain
    try check(!outGroup.includes(resolved), "a row changed to another review reason leaves its old scope")
    try check(records.first { $0.id == "edited-private-id" }!.reviewExplanation.contains("Money went out"),
              "receipt explanation identifies the unresolved money-out decision")
    try check(records.first { $0.id == "in-type" }!.reviewExplanation.contains("not automatically income"),
              "money-in uncertainty is never described as an expense")
    let summary = report.countsSummary(records: records, sources: nil)
    for privateValue in ["PRIVATE_NAME_SENTINEL", "edited-private-id", "987654321", "₹", "XX0001"] {
        try check(!summary.contains(privateValue), "counts summary excludes private fields")
    }
    try check(summary.contains("Original SMS analysis: not run") && summary.contains("Coverage incomplete"),
              "summary distinguishes saved-record evidence from source analysis and completeness")
    let empty = ReviewDiagnostics(records: [])
    try check(empty.total == 0 && empty.reasons.isEmpty && empty.banks.isEmpty, "empty diagnostic report")
    let large = (0..<1200).map { row("large-\($0)", $0 % 3 == 0 ? .uncertain : .debit, .uncertain, Bank.allCases[$0 % 3]) }
    let largeReport = ReviewDiagnostics(records: large)
    try check(largeReport.total == 1200 && largeReport.reasons.reduce(0) { $0 + $1.count } == 1200,
              "larger diagnostic history retains exact memberships")
}

func reviewSourceDiagnosticsChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-diagnostics-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transactions.sqlite")
    let fixtures = [
        message("JD-IDFCFB", "Your A/c XX0001 debited by Rs. 101.01 on 10/10/26; FICTIONAL RECIPIENT credited. RRN DIAGSOURCE001", "diag-dual"),
        message("VM-ICICIB", "INR 102.02 debited to FICTIONAL SHOP via UPI on 11/10/26. Ref DIAGSOURCE002", "diag-upi"),
        message("AX-AXISBK", "INR 103.03 debited on 12/10/26. Ref DIAGSOURCE003", "diag-debit"),
        message("VM-ICICIB", "INR 104.04 debited and credited on 13/10/26. Ref DIAGSOURCE004", "diag-direction"),
        message("AX-AXISBK", "INR 105.05 spent at FICTIONAL RECOGNIZED on 14/10/26. Ref DIAGSOURCE005", "diag-recognized"),
        message("AX-AXISBK", "INR 106.06 debited on 15/10/26. Ref DIAGSOURCE006", "diag-missing"),
        message("AX-AXISBK", "INR 107.07 debited on 16/10/26. Ref DIAGSOURCE007", "diag-stopped-parsing"),
        message("AX-AXISBK", "INR 108.08 debited on 17/10/26. Ref DIAGSOURCE008", "diag-deleted"),
        message("AX-AXISBK", "Your balance is INR 999", "diag-unparsed"),
    ]
    let store = try TransactionStore(url: url)
    _ = try store.ingest(fixtures)
    var recognized = try store.load().first { $0.amountPaise == 10505 }!
    recognized.type = .uncertain
    try store.save(recognized)
    let deleted = try store.load().first { $0.amountPaise == 10808 }!
    try store.delete(id: deleted.id)
    let records = try store.load()
    var linked: [String: [SourceIdentity]] = [:]
    for record in records { linked[record.id] = try store.sources(id: record.id) }
    let noLongerParses = message("AX-AXISBK", "Payment of INR 107.07 for credit card XX0001 is due. Ignore if paid.", "diag-stopped-parsing")
    let messages = fixtures.filter { !["diag-missing", "diag-stopped-parsing"].contains($0.guid) } + [noLongerParses]
    let bytesBefore = try Data(contentsOf: url)
    let analysis = ReviewDiagnostics.SourceAnalysis(records: records, messages: messages, sources: linked)
    func finding(_ amount: Int64) -> ReviewDiagnostics.SourceFinding? {
        analysis.findings[records.first { $0.amountPaise == amount }!.id]
    }
    try check(finding(10101) == .accountDebitRecipientCredit && finding(10202) == .upiPurposeUnclear &&
              finding(10303) == .genericDebit && finding(10404) == .directionUnclear,
              "source diagnostic patterns explain conservative review decisions")
    try check(finding(10505) == .currentParserRecognizes && finding(10606) == .unavailable && finding(10707) == .noLongerRecognized,
              "source report distinguishes current-parser proposals, missing and rejected sources")
    try check(analysis.findings.count == 7 && !analysis.findings.keys.contains(deleted.id),
              "source diagnostic covers active review records only, not deleted or wholly unparsed sources")
    try check(try store.load() == records && Data(contentsOf: url) == bytesBefore,
              "diagnostic analysis changes no saved transaction or database bytes")
    try check(records.allSatisfy { !$0.isConfirmedExpense }, "analyzing sources never confirms spending")
    let report = ReviewDiagnostics(records: records)
    let summary = report.countsSummary(records: records, sources: analysis)
    for privateValue in ["FICTIONAL RECIPIENT", "FICTIONAL SHOP", "101.01", "XX0001", "DIAGSOURCE", "diag-dual"] + records.map(\.id) {
        try check(!summary.contains(privateValue), "source summary excludes SMS fields and source/record identities")
    }
    try check(summary.contains("IDFC FIRST · Account debited") && summary.contains("ICICI · UPI mentioned"),
              "counts-only summary retains useful bank and pattern breakdown")
    for group in analysis.groups(records: records) {
        try check(Set(records.filter(group.includes).map(\.id)) == group.transactionIDs,
                  "source-pattern drill-through reconciles with active review records")
    }
    let denied = ReviewDiagnostics.SourceAnalysis(records: records, failure: .access)
    try check(denied.findings.values.allSatisfy { $0 == .unavailable } &&
              report.countsSummary(records: records, sources: denied).contains("Read unavailable"),
              "permission failure does not fabricate source findings or lose the saved report")

    // Receipt dates, SMS service, sender and immutable source keys all matter.
    let out = fixtures[0]
    let outside = message(out.sender, out.text, out.guid, Importer.endExclusive)
    let personal = message("FRIEND", out.text, out.guid)
    let outgoing = Message(guid: out.guid, sender: out.sender, text: out.text, receivedAt: out.receivedAt, service: "SMS", isFromMe: true)
    let imessage = Message(guid: out.guid, sender: out.sender, text: out.text, receivedAt: out.receivedAt, service: "iMessage", isFromMe: false)
    for invalid in [outside, personal, outgoing, imessage] {
        let bounded = ReviewDiagnostics.SourceAnalysis(records: records, messages: [invalid], sources: linked)
        try check(bounded.findings.values.allSatisfy { $0 == .unavailable }, "source diagnostic honors all import boundaries")
    }
    let unrelated = message(out.sender, out.text, "different-source-identity")
    let exact = ReviewDiagnostics.SourceAnalysis(records: records, messages: [unrelated], sources: linked)
    try check(exact.findings.values.allSatisfy { $0 == .unavailable }, "similar wording cannot match an unrelated source")

    // An alternate parsed source wins over a reminder; no-GUID text changes
    // remain unavailable rather than being guessed from matching financial fields.
    let alternate = message(fixtures[2].sender, fixtures[2].text, "alternate-source")
    let row = records.first { $0.amountPaise == 10303 }!
    let reminder = message(fixtures[2].sender, "Your credit card amount due is INR 103.03", fixtures[2].guid)
    let aliasAnalysis = ReviewDiagnostics.SourceAnalysis(records: [row], messages: [reminder, alternate],
        sources: [row.id: [ImportIdentity.source(reminder), ImportIdentity.source(alternate)]])
    try check(aliasAnalysis.findings[row.id] == .genericDebit, "available parsed alternate source wins over reminder")
    let noGUID = message(out.sender, out.text, "")
    let changed = message(out.sender, out.text + " Changed", "")
    let noGUIDAnalysis = ReviewDiagnostics.SourceAnalysis(records: [row], messages: [changed], sources: [row.id: [ImportIdentity.source(noGUID)]])
    try check(noGUIDAnalysis.findings[row.id] == .unavailable, "no-GUID source changes do not guess an identity")
}
