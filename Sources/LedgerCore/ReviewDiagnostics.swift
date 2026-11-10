import Foundation

// Read-only diagnostics. Labels are fixed; source text never enters a report.
package struct ReviewDiagnostics: Sendable {
    package enum Reason: String, CaseIterable, Sendable {
        case direction, moneyOutType, moneyInType, conflictingDetails

        package var title: String {
            switch self {
            case .direction: "Money direction unclear"
            case .moneyOutType: "Money out · Payment type unclear"
            case .moneyInType: "Money in · Payment type unclear"
            case .conflictingDetails: "Direction, type or income tag conflict"
            }
        }
        package var explanation: String {
            switch self {
            case .direction: "Confirm whether money went out of or came into your account, then choose the payment type."
            case .moneyOutType: "Money went out, but Ledger cannot tell whether it was an expense, transfer or card payment. Choose the type; a category alone cannot decide this."
            case .moneyInType: "Money came in, but its payment type still needs confirmation. Incoming payments are not automatically income."
            case .conflictingDetails: "The saved direction, payment type or Income / Salary tag do not agree. Check those fields together before saving."
            }
        }
        package static func forRecord(_ row: TransactionRecord) -> Self? {
            guard row.needsReview else { return nil }
            // An unknown direction is its own unresolved decision, even when a
            // known type also makes that direction inconsistent.
            if row.direction == .uncertain { return .direction }
            if !row.consistent { return .conflictingDetails }
            return row.direction == .debit ? .moneyOutType : .moneyInType
        }
    }

    package struct Group: Identifiable, Sendable {
        package let id: String
        package let title: String
        package let transactionIDs: Set<String>
        package var reason: Reason? = nil
        package var bank: Bank? = nil
        package var count: Int { transactionIDs.count }
        package func includes(_ row: TransactionRecord) -> Bool {
            row.needsReview && transactionIDs.contains(row.id) &&
                (reason == nil || Reason.forRecord(row) == reason) && (bank == nil || row.bank == bank)
        }
    }

    package let total: Int
    package let categorized: Int
    package let savedCorrections: Int
    package let reasons: [Group]
    package let banks: [Group]

    package init(records: [TransactionRecord]) {
        let rows = records.filter(\.needsReview)
        total = rows.count
        categorized = rows.filter { $0.category != .uncategorized }.count
        savedCorrections = rows.filter(\.manuallyEdited).count
        reasons = Reason.allCases.compactMap { reason in
            let ids = Set(rows.filter { Reason.forRecord($0) == reason }.map(\.id))
            return ids.isEmpty ? nil : Group(id: reason.rawValue, title: reason.title, transactionIDs: ids, reason: reason)
        }.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        banks = Bank.allCases.compactMap { bank in
            let ids = Set(rows.filter { $0.bank == bank }.map(\.id))
            return ids.isEmpty ? nil : Group(id: bank.rawValue, title: bank.rawValue, transactionIDs: ids, bank: bank)
        }
    }

    package enum SourceFinding: String, CaseIterable, Sendable {
        case currentParserRecognizes, accountDebitRecipientCredit, upiPurposeUnclear
        case genericDebit, directionUnclear, otherUncertainty, noLongerRecognized, unavailable

        package var title: String {
            switch self {
            case .currentParserRecognizes: "A recognition suggestion is available"
            case .accountDebitRecipientCredit: "Account debited, recipient credited · Purpose unclear"
            case .upiPurposeUnclear: "UPI mentioned · Purpose unclear"
            case .genericDebit: "Debit notice · Purpose unclear"
            case .directionUnclear: "SMS does not establish money direction"
            case .otherUncertainty: "Other unresolved payment wording"
            case .noLongerRecognized: "Original SMS no longer recognized as a transaction"
            case .unavailable: "Original SMS unavailable"
            }
        }
        package var explanation: String {
            switch self {
            case .currentParserRecognizes: "Ledger can now suggest a direction and type, but the saved record still needs review. Compare the original and explicitly Save; saved corrections are never overwritten here."
            case .accountDebitRecipientCredit: "Ledger identifies which account lost money. This wording alone does not prove whether the payment was spending, a transfer or a card payment."
            case .upiPurposeUnclear: "UPI identifies a payment method, not whether the payment was spending or a transfer. The purpose needs confirmation."
            case .genericDebit: "A debit confirms money out. The message has no recognized evidence for expense, transfer or card payment."
            case .directionUnclear: "Ledger cannot tell which way money moved for your account. Review the original locally."
            case .otherUncertainty: "The source is available, but its wording still leaves a decision unresolved."
            case .noLongerRecognized: "The original SMS is available, but Ledger's current rules do not recognize it as a transaction. This report does not remove or change the saved record."
            case .unavailable: "The linked source may be missing, outside the fixed receipt window or undecodable. Saved transactions remain editable."
            }
        }
        package static func inspect(_ message: Message) -> Self {
            guard let parsed = Parser.parse(message) else { return .noLongerRecognized }
            if !parsed.needsReview { return .currentParserRecognizes }
            if parsed.direction == .uncertain { return .directionUnclear }
            if parsed.resolvedIDFCDualVerbDebit { return .accountDebitRecipientCredit }
            if parsed.direction == .debit && parsed.type == .uncertain {
                if message.text.range(of: #"\b(?:UPI|VPA)\b"#, options: .caseInsensitive.union(.regularExpression)) != nil {
                    return .upiPurposeUnclear
                }
                return .genericDebit
            }
            return .otherUncertainty
        }
    }

    package struct SourceAnalysis: Sendable {
        package enum ReadFailure: Sendable {
            case access, schema, read
            package var explanation: String {
                switch self {
                case .access: "Messages is unavailable or access was denied. Your saved-record breakdown still works. Quit Ledger and check Full Disk Access for the installed app before trying again."
                case .schema: "This Messages database format is unsupported. Your saved records and their review reasons are unchanged."
                case .read: "Messages could not be read. Try again after Messages finishes syncing. Your saved records are unchanged."
                }
            }
        }
        package let findings: [String: SourceFinding]
        package var failure: ReadFailure? = nil

        package init(records: [TransactionRecord], messages: [Message], sources: [String: [SourceIdentity]], windows: [ImportWindow] = [.legacy]) {
            // Enforce the same source boundary even for callers with in-memory
            // fixtures. Never match by merchant name, row position or bank alone.
            var available: [String: Message] = [:]
            for message in messages where !message.isFromMe && message.service.uppercased() == "SMS" &&
                Bank.from(sender: message.sender) != nil && !message.text.isEmpty &&
                windows.contains(where: { $0.contains(message.receivedAt) }) {
                let key = ImportIdentity.source(message).key
                if available[key] == nil { available[key] = message }
            }
            var result: [String: SourceFinding] = [:]
            for row in records where row.needsReview {
                let linked = (sources[row.id] ?? []).compactMap { available[$0.key] }
                // Match the deterministic parsed-source preference used by import;
                // a stale reminder alias must not hide an available parsed source.
                let source = linked.first { Parser.parse($0) != nil } ?? linked.first
                result[row.id] = source.map(SourceFinding.inspect) ?? .unavailable
            }
            findings = result
        }

        package init(records: [TransactionRecord], failure: ReadFailure) {
            findings = Dictionary(uniqueKeysWithValues: records.filter(\.needsReview).map { ($0.id, .unavailable) })
            self.failure = failure
        }

        package func groups(records: [TransactionRecord]) -> [Group] {
            SourceFinding.allCases.compactMap { finding in
                let ids = Set(records.filter { $0.needsReview && findings[$0.id] == finding }.map(\.id))
                return ids.isEmpty ? nil : Group(id: finding.rawValue, title: finding.title, transactionIDs: ids)
            }.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        }
    }

    // User-initiated copying only. Fixed labels and counts; no interpolated
    // merchants, SMS, amounts, dates, record/source identities or account fields.
    package func countsSummary(records: [TransactionRecord], sources: SourceAnalysis?) -> String {
        var lines = ["Ledger Needs Review · Counts only", "Scope: active saved transactions; all saved dates.",
            "Manual SMS receipt scans use Asia/Kolkata. Coverage incomplete.",
            "Needs Review: \(total)", "Already categorized: \(categorized)", "Saved corrections protected: \(savedCorrections)", "Reasons:"]
        lines += reasons.map { "\($0.title): \($0.count)" }
        lines.append("By bank:")
        lines += banks.map { "\($0.title): \($0.count)" }
        if let sources {
            lines.append("Local source analysis\(sources.failure == nil ? "" : " · Read unavailable"):")
            lines += sources.groups(records: records).map { "\($0.title): \($0.count)" }
            for bank in banks {
                for finding in SourceFinding.allCases {
                    let count = bank.transactionIDs.filter { sources.findings[$0] == finding }.count
                    if count > 0 { lines.append("\(bank.title) · \(finding.title): \(count)") }
                }
            }
        } else { lines.append("Original SMS analysis: not run.") }
        lines.append("Diagnostic counts only; no classifications changed. Not an accuracy or completeness measure.")
        return lines.joined(separator: "\n")
    }
}
