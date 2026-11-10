import Foundation

// Small, explainable offline rules. Suggestions are not confirmations or saved edits.
package enum MerchantIntelligence {
    package static func extract(from text: String) -> String? {
        // Bank support instructions are not transaction participants. Stop before
        // balances/limits and fraud-help footers, then reject numeric-only values.
        let footer = #"\b(?:(?:avl\.?|available)\s*(?:limit|bal(?:ance)?)|if\s+not\s+you|not\s+you|call\s+\+?\d[\d -]*|sms\s+block|for\s+(?:any\s+)?(?:queries|assistance))\b"#
        let clause = text.range(of: footer, options: [.regularExpression, .caseInsensitive])
            .map { String(text[..<$0.lowerBound]) } ?? text
        let stop = #"(?=\s+\b(?:on(?=\s+\d)|via|ref(?:erence)?|upi|avl|bal|available|using)\b|[;!?]|\.(?=\s|$)|$)"#
        let name = #"([\p{L}\p{N}][\p{L}\p{N} &._*'@/+\-]{0,90}?)"# + stop
        let date = #"\d{1,2}[-/](?:[A-Za-z]{3,9}|\d{1,2})[-/]\d{2,4}"#
        let time = #"(?:\s+(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?)?"#
        let patterns = [
            #"\bon\s+"# + date + time + #"\s+(?:on|at)\s+"# + name,
            #"\bcard\s+(?:no\.?\s*)?[Xx*]{2,}\d{2,4}\s+(?:at|on)\s+(?!\d{1,2}[-/])"# + name,
            #"\bat\s+"# + name,
            #"\b(?:to|from)\s+"# + name,
        ]
        for pattern in patterns {
            guard let value = capture(clause, pattern), let clean = clean(value) else { continue }
            return canonicalName(clean)
        }
        return nil
    }

    package static func canonicalName(_ merchant: String) -> String {
        let value = merchant.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let upper = value.uppercased()
        if upper == "AMAZON" || upper == "AMAZON PAY" || upper.hasPrefix("AMAZON PAY ") ||
            upper == "AMZN MKTPLACE" || upper.hasPrefix("AMZN MKTPLACE ") { return "Amazon" }
        if upper == "NETFLIX" || upper == "NETFLIX.COM" { return "Netflix" }
        if upper == "SPOTIFY" { return "Spotify" }
        return value
    }

    package static func suggestedCategory(merchant: String, type: TransactionType) -> SpendingCategory? {
        guard type == .expense else { return nil }
        let name = canonicalName(merchant)
        if name == "Amazon" { return .shopping }
        if name == "Netflix" || name == "Spotify" { return .subscriptions }
        if name.range(of: #"\b(?:cafe|café|coffee|restaurant)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .foodDining
        }
        if name.range(of: #"\b(?:groceries|grocery|supermarket)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .groceries
        }
        return nil
    }

    // Exact, versioned keys: no substring/fuzzy matching for saved rules.
    package static func ruleKey(for merchant: String) -> String? {
        let name = canonicalName(merchant)
        guard (2...90).contains(name.count), clean(name) != nil else { return nil }
        let folded = name.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !["recipient not identified", "unknown", "unknown merchant", "needs identification", "credit card payment"].contains(folded) else { return nil }
        return "merchant-v1|" + folded
    }

    private static func clean(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"\p{L}"#, options: .regularExpression) != nil,
              value.range(of: #"^[+0-9][0-9 -]{6,}(?:\b|$)"#, options: .regularExpression) == nil else { return nil }
        let lower = value.lowercased()
        guard !lower.hasPrefix("your "), !lower.hasPrefix("a/c"),
              !lower.hasPrefix("account "), !lower.hasPrefix("acct "),
              value.range(of: #"^card\s+[Xx*]{2,}\d"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return value
    }
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
