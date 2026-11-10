import Foundation

// Separate from purpose-category rules. Exact names within one bank only;
// no new alias/fuzzy matching and never match by a bank's SMS sender.
package struct RecipientTypeRule: Identifiable, Equatable, Sendable {
    package let id: String
    package let recipient: String
    package let bank: Bank
    package var type: TransactionType
    package var category: SpendingCategory?
    package static let allowedTypes: [TransactionType] = [.expense, .transfer, .cardPayment]

    package init?(recipient: String, bank: Bank, type: TransactionType, category: SpendingCategory? = nil) {
        guard let key = Self.key(recipient: recipient, bank: bank), Self.allowedTypes.contains(type),
              category == nil || (type == .expense && category != .incomeSalary) else { return nil }
        id = key; self.recipient = recipient.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.bank = bank; self.type = type; self.category = category
    }
    package static func key(recipient: String, bank: Bank) -> String? {
        let name = recipient.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...90).contains(name.count), MerchantIntelligence.ruleKey(for: name) != nil else { return nil }
        let folded = name.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let generic: Set<String> = ["payment", "merchant", "recipient", "upi", "vpa", "neft", "imps", "rtgs", "bank", "razorpay", "payu", "cashfree", "phonepe", "paytm"]
        guard !generic.contains(folded), !folded.hasPrefix("own "),
              name.range(of: #"^(?:[a-z]{2}-)?(?:axisbk|icicib|idfcfb|axis bank|icici bank|idfc first(?: bank)?)$"#,
                         options: [.regularExpression, .caseInsensitive]) == nil,
              name.range(of: #"\b(?:account|acct|card|balance|limit|reference|rrn|debited|credited)\b|\ba/c\b"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return "recipient-type-v1|\(bank.rawValue)|\(folded)"
    }
    package static func eligible(_ row: TransactionRecord) -> Bool {
        row.valid && row.direction == .debit && row.type == .uncertain &&
            row.category != .incomeSalary && key(recipient: row.merchant, bank: row.bank) != nil
    }
    package static func allowsAutomatic(_ message: Message) -> Bool {
        message.text.range(of: #"\b(?:failed|failure|declined|cancelled|canceled|pending|scheduled|initiated|refund(?:ed)?|reversal|reversed|reminder|due|will\s+be|has\s+not|not\s+(?:debited|paid|completed|successful))\b"#,
                           options: [.regularExpression, .caseInsensitive]) == nil
    }
}

package enum RecipientReview {
    package struct Group: Identifiable, Equatable, Sendable {
        package let id: String
        package let recipient: String
        package let bank: Bank
        package let records: [TransactionRecord]
        package let knownTypes: Set<TransactionType>
        package let remembered: RecipientTypeRule?
        package var count: Int { records.count }
        package func canRemember(_ type: TransactionType) -> Bool {
            RecipientTypeRule.allowedTypes.contains(type) && knownTypes.allSatisfy { $0 == type }
        }
    }
    package static func groups(records: [TransactionRecord], rules: [RecipientTypeRule]) -> [Group] {
        let grouped = Dictionary(grouping: records.filter(RecipientTypeRule.eligible)) {
            RecipientTypeRule.key(recipient: $0.merchant, bank: $0.bank)!
        }
        let known = knownTypes(records: records)
        return grouped.map { key, rows in
            let sorted = rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            return Group(id: key, recipient: sorted[0].merchant, bank: sorted[0].bank, records: sorted,
                knownTypes: known[key] ?? [], remembered: rules.first { $0.id == key })
        }.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
    // Only explicit known types establish conflicts, not an earlier automatic
    // choice made by a remembered rule that the user may later replace.
    package static func knownTypes(records: [TransactionRecord]) -> [String: Set<TransactionType>] {
        var result: [String: Set<TransactionType>] = [:]
        for row in records where !row.needsReview && row.direction == .debit && row.recipientTypeRuleKey == nil {
            if let key = RecipientTypeRule.key(recipient: row.merchant, bank: row.bank) {
                result[key, default: []].insert(row.type)
            }
        }
        return result
    }
    package struct Plan: Sendable {
        package let group: Group
        package let selectedIDs: Set<String>
        package let type: TransactionType
        package let category: SpendingCategory?
        package let remember: Bool
        package init(group: Group, selectedIDs: Set<String>, type: TransactionType, category: SpendingCategory?, remember: Bool) {
            self.group = group; self.selectedIDs = selectedIDs; self.type = type; self.category = category; self.remember = remember
        }
        package var selected: [TransactionRecord] { group.records.filter { selectedIDs.contains($0.id) } }
        package var proposed: [TransactionRecord] {
            selected.map { record in
                var value = record
                value.type = type; value.manuallyEdited = true; value.recipientTypeRuleKey = nil
                if type == .expense, value.category == .uncategorized, let category { value.category = category }
                return value
            }
        }
        package var amountPaise: Int64? {
            var total: Int64 = 0
            for row in selected {
                let sum = total.addingReportingOverflow(row.amountPaise)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
            return total
        }
    }
}
