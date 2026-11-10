import Foundation

// Local, declarative merchant defaults. No SMS/network access. A category is a
// purpose estimate, never evidence that a payment is an expense or confirmed.
// Corporate aliases checked against official public pages (not private messages):
// https://blinkit.com/terms and https://blinkit.com/privacy
// https://www.zepto.com/s/terms-of-service and https://www.zepto.com/s/de-agreement
// https://www.swiggy.com/terms-and-conditions
package enum MerchantCatalog {
    package struct Entry: Sendable {
        package let id: String
        package let name: String
        package let aliases: [String]
        package let category: SpendingCategory
        package var automatic = true
    }
    package static let entries: [Entry] = [
        .init(id: "swiggy-instamart", name: "Swiggy Instamart", aliases: ["swiggy instamart", "swiggyinstamart", "instamart"], category: .groceries),
        .init(id: "swiggy", name: "Swiggy", aliases: ["swiggy", "swiggy food", "swiggyfood", "swiggyfoods"], category: .foodDining),
        // Shared historical Swiggy company labels do not identify food vs grocery.
        .init(id: "swiggy-shared", name: "Swiggy shared company", aliases: ["bundl", "bundl technologies"], category: .uncategorized, automatic: false),
        .init(id: "zepto", name: "Zepto", aliases: ["zepto", "zepto now", "zeptonow", "zeptomarketplace", "kiranakart", "kirana kart"], category: .groceries),
        .init(id: "blinkit", name: "Blinkit", aliases: ["blinkit", "blink commerce", "blinkcommerce", "grofers india", "grofers"], category: .groceries),
        .init(id: "swish", name: "Swish", aliases: ["swish", "swish food", "swishfood"], category: .foodDining),
        .init(id: "zomato", name: "Zomato", aliases: ["zomato"], category: .foodDining),
        .init(id: "bigbasket", name: "BigBasket", aliases: ["bigbasket", "big basket", "bbnow", "bb now"], category: .groceries),
        .init(id: "dmart", name: "DMart", aliases: ["dmart", "d mart", "dmart ready"], category: .groceries),
        .init(id: "amazon", name: "Amazon", aliases: ["amazon", "amazon pay", "amzn mktplace"], category: .shopping, automatic: false),
        .init(id: "flipkart", name: "Flipkart", aliases: ["flipkart"], category: .shopping, automatic: false),
        .init(id: "myntra", name: "Myntra", aliases: ["myntra"], category: .shopping),
        .init(id: "ajio", name: "AJIO", aliases: ["ajio"], category: .shopping),
        .init(id: "uber", name: "Uber", aliases: ["uber", "uber trip", "ubertrip"], category: .transportation),
        .init(id: "ola", name: "Ola", aliases: ["ola", "ola cabs", "olacabs"], category: .transportation),
        .init(id: "rapido", name: "Rapido", aliases: ["rapido"], category: .transportation),
        .init(id: "irctc", name: "IRCTC", aliases: ["irctc"], category: .travel),
        .init(id: "makemytrip", name: "MakeMyTrip", aliases: ["makemytrip", "make my trip"], category: .travel),
        .init(id: "goibibo", name: "Goibibo", aliases: ["goibibo"], category: .travel),
        .init(id: "apollo-pharmacy", name: "Apollo Pharmacy", aliases: ["apollo pharmacy", "apollopharmacy"], category: .health),
        .init(id: "pharmeasy", name: "PharmEasy", aliases: ["pharmeasy", "pharm easy"], category: .health),
        .init(id: "tata-1mg", name: "Tata 1mg", aliases: ["tata 1mg", "tata1mg", "1mg"], category: .health),
        .init(id: "netmeds", name: "Netmeds", aliases: ["netmeds"], category: .health),
        .init(id: "airtel", name: "Airtel", aliases: ["airtel", "airtel recharge"], category: .billsUtilities),
        .init(id: "jio", name: "Jio", aliases: ["jio", "jio fiber", "jiofiber"], category: .billsUtilities),
        .init(id: "bsnl", name: "BSNL", aliases: ["bsnl"], category: .billsUtilities),
        .init(id: "netflix", name: "Netflix", aliases: ["netflix"], category: .subscriptions),
        .init(id: "spotify", name: "Spotify", aliases: ["spotify"], category: .subscriptions),
        // Recognize specific subscription services, not every Google/Apple purchase.
        .init(id: "google-one", name: "Google One", aliases: ["google one", "googleone", "google storage", "google google one"], category: .subscriptions),
        .init(id: "youtube-premium", name: "YouTube Premium", aliases: ["youtube premium", "youtubepremium", "google youtube premium", "google youtubepremium"], category: .subscriptions),
        .init(id: "apple-music", name: "Apple Music", aliases: ["apple music", "applemusic"], category: .subscriptions),
        .init(id: "icloud", name: "iCloud", aliases: ["icloud", "icloud plus", "apple icloud", "apple icloud plus"], category: .subscriptions),
        // Apple Media was confirmed by the user for their recurring payments.
        .init(id: "apple-media", name: "Apple Media", aliases: ["apple media", "applemedia"], category: .subscriptions),
        // Broad marketplace/video descriptors can also be one-off purchases.
        .init(id: "google-play", name: "Google Play (check subscription)", aliases: ["google play", "googleplay"], category: .subscriptions, automatic: false),
        .init(id: "youtube-billing", name: "YouTube (check subscription)", aliases: ["google youtube", "youtube"], category: .subscriptions, automatic: false),
        // This billing label may also describe a one-off app/content purchase.
        .init(id: "apple-billing", name: "Apple billing (check subscription)", aliases: ["apple com bill", "itunes com bill"], category: .subscriptions, automatic: false),
    ]

    private static func tokens(_ value: String) -> [String] {
        // For a VPA use the merchant component, never infer a merchant from its bank.
        let local = value.split(separator: "@", maxSplits: 1).first.map(String.init) ?? value
        let normalized = local.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        var words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        let wrappers: Set<String> = ["www", "https", "http", "upi", "payu", "razorpay", "rzp", "rzpx", "paytm", "ccavenue", "billdesk"]
        while let first = words.first, wrappers.contains(first) { words.removeFirst() }
        return words
    }

    private struct PreparedAlias: Sendable {
        let entry: Entry
        let prefix: [String]
        let score: Int
    }
    // The catalog is immutable. Normalize its aliases once, not for every row
    // and every redraw. Keep the matching order and normalization unchanged.
    private static let preparedAliases: [PreparedAlias] = entries.flatMap { entry in
        entry.aliases.map { alias in
            let prefix = tokens(alias)
            return PreparedAlias(entry: entry, prefix: prefix, score: prefix.joined().count)
        }
    }
    private static let suffixes: Set<String> = ["e", "pos", "ecom", "com", "in", "co", "online", "app", "pay", "payment", "payments", "pvt", "private", "ltd", "limited", "india", "retail", "store", "stores", "services", "technologies", "tech", "food", "foods", "foodtech", "marketplace", "bangalore", "bengaluru", "delhi", "mumbai", "hyderabad", "trip"]

    package static func match(_ merchant: String) -> Entry? {
        let words = tokens(merchant)
        guard !words.isEmpty else { return nil }
        var best: (entry: Entry, score: Int)?
        for alias in preparedAliases {
            guard !alias.prefix.isEmpty, words.starts(with: alias.prefix) else { continue }
            let remaining = words.dropFirst(alias.prefix.count)
            guard remaining.allSatisfy({ suffixes.contains($0) || $0.range(of: #"^[a-z]{0,3}[0-9]{2,}$"#, options: .regularExpression) != nil }) else { continue }
            if best == nil || alias.score > best!.score { best = (alias.entry, alias.score) }
        }
        return best?.entry
    }
}
