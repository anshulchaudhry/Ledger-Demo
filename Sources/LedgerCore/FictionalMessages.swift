import Foundation

// Compiled fictional fixtures only; real source text never enters this file or the store.
package enum FictionalMessages {
    package static let all: [Message] = {
        let examples: [(String, String, Int, Int)] = [
            ("AX-AXISBK", "INR 325.00 spent at Maple Cafe on 30/10/26 using card XX0001.", 10, 30),
            ("JD-IDFCFB", "Your A/c XX0002 debited by Rs. 1,100.00 on 29/10/26. Payment completed. Ref DEMO0002.", 10, 29),
            ("VM-ICICIB", "INR 5,000.00 debited to Own savings account on 28/10/26. Self transfer. Ref DEMO0003.", 10, 28),
            ("AX-AXISBK", "INR 2,400.00 debited on 25/10/26 for credit card bill payment. Card XX0001. Ref DEMO0004.", 10, 25),
            ("VM-ICICIB", "INR 649.00 refunded from Willow Books on 22/10/26 to A/c XX0003. Ref DEMO0005.", 10, 22),
            ("JD-IDFCFB", "Rs. 1,800.00 received from Example sender on 15/10/26 in A/c XX0002. Ref DEMO0006.", 10, 15),
            ("JD-IDFCFB", "Rs. 750.00 debited and credited on 20/09/26. Please check your account. Ref DEMO0007.", 9, 20),
            ("AX-AXISBK", "INR 1,280.50 spent at Market Basket on 30/07/26 using card XX0001.", 7, 30),
            ("VM-ICICIB", "INR 183.50 spent using ICICI Bank Card XX0003 on 27-Oct-26 on AMAZON PAY TEST. Avl Limit INR 9,000. If not you, call 1800000000 or SMS BLOCK to 9000000000.", 10, 27),
            ("AX-AXISBK", "INR 210.00 spent at Willow Grocery on 26/10/26 using card XX0001.", 10, 26),
            ("VM-ICICIB", "INR 299.00 spent at Netflix on 24/10/26 using card XX0003.", 10, 24),
            ("AX-AXISBK", "INR 121.00 spent at RZP*SWIGGY.COM 123456 on 23/10/26. Ref DEMOFOOD01.", 10, 23),
            ("VM-ICICIB", "INR 232.00 spent using ICICI Bank Card XX0003 on 21-Oct-26 on ZEPTO NOW PRIVATE LIMITED. Avl Limit INR 9,000.", 10, 21),
            ("AX-AXISBK", "INR 343.00 spent at SWIGGY_INSTAMART PRIVATE LIMITED on 19/10/26. Ref DEMOFOOD03.", 10, 19),
            ("VM-ICICIB", "INR 454.00 debited to BLINK COMMERCE PVT LTD on 17/10/26. Ref DEMOFOOD04.", 10, 17),
            ("AX-AXISBK", "INR 565.00 spent at SWISH TECHNOLOGIES PRIVATE LIMITED on 13/10/26. Ref DEMOFOOD05.", 10, 13),
            ("AX-AXISBK", "INR 676.00 debited to BUNDL TECHNOLOGIES PRIVATE LIMITED on 11/10/26. Ref DEMOFOOD06.", 10, 11),
            ("AX-AXISBK", "INR 199.00 spent at GOOGLE*Google One on 10/10/26. Ref DEMORECUR01.", 10, 10),
            ("VM-ICICIB", "INR 149.00 spent at Apple Media on 09/10/26. Ref DEMORECUR02.", 10, 9),
            ("AX-AXISBK", "INR 99.00 spent at APPLE.COM/BILL on 08/10/26. Ref DEMORECUR03.", 10, 8),
            ("VM-ICICIB", "INR 899.00 spent at GOOGLE on 07/10/26. Ref DEMORECUR04.", 10, 7),
            ("JD-IDFCFB", "Your A/c XX0002 debited by Rs. 432.10 on 06/10/26; CRED credited. RRN DEMOCRED01. Available balance Rs. 9,000.00. Team IDFC FIRST Bank", 10, 6),
            ("VM-ICICIB", "INR 123.45 debited to Cedar Market via UPI on 05/10/26. Ref DEMOREVIEW01.", 10, 5),
            ("AX-AXISBK", "INR 234.56 debited and credited on 04/10/26. Ref DEMOREVIEW02.", 10, 4),
            ("JD-IDFCFB", "Your A/c XX0002 debited by Rs. 345.67 on 03/10/26; Cedar Recipient credited. RRN DEMOREVIEW03.", 10, 3),
            ("VM-ICICIB", "INR 66.78 debited to Cedar Market via UPI on 02/10/26. Ref DEMOREVIEW04.", 10, 2),
            ("AX-AXISBK", "INR 142.35 spent at Fictional November Cafe on 03/11/26 using card XX0001. Ref DEMONOV01.", 11, 3),
            ("AX-AXISBK", "INR 87.25 spent at Fictional Refresh Cafe on 09/11/26 using card XX0001. Ref DEMONOV02.", 11, 9),
            ("AX-AXISBK", "INR 246.80 credited to A/c no. XX0004 at 09-11-26 11:59:59 IST\nRef: IMPS/P2A/123456789012/MIRA SEN\nFor any details, call 1800000000 - Axis Bank", 11, 9),
        ]
        let examplesWithIDs = examples.enumerated().map { index, item in
            Message(guid: "ledger-demo-v1-\(index)", sender: item.0, text: item.1,
                receivedAt: TransactionRecord.calendar.date(from: DateComponents(year: 2026, month: item.2, day: item.3, hour: 12))!,
                service: "SMS", isFromMe: false)
        }
        let received = TransactionRecord.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let linkedReceipts = [
            Message(guid: "ledger-demo-card-link-funding", sender: "JD-IDFCFB",
                    text: "Your A/c XX0002 debited by Rs. 276.58 on 01/10/26; CRED credited. RRN DEMOLINK01.",
                    receivedAt: received, service: "SMS", isFromMe: false),
            Message(guid: "ledger-demo-card-link-issuer", sender: "AX-AXISBK",
                    text: "Payment of INR 276.58 has been received towards your Axis Bank Credit Card XX0001 on 01-10-26 - Axis Bank",
                    receivedAt: received.addingTimeInterval(55), service: "SMS", isFromMe: false)
        ]
        return examplesWithIDs + linkedReceipts + monthlyActivity + reviewAndImportCases
    }()

    // Stable dates and IDs make Demo imports repeatable across launches.
    private static var monthlyActivity: [Message] {
        let senders = ["AX-AXISBK", "VM-ICICIB", "JD-IDFCFB"]
        let shops = ["Juniper Bakery", "Blinkit", "Willow Books", "Airtel", "Netflix", "Fictional Rail", "Cedar Sports Club", "Maple Pharmacy"]
        return (8...10).flatMap { month in
            (1...28).map { day in
                let sender = senders[(day + month) % senders.count]
                let date = "\(day)/\(month)/26"
                let reference = "DEMOBULK\(month)D\(day)"
                let amount = "\(115 + day * (month + 4)).\(String(format: "%02d", (day * 7) % 100))"
                let text: String
                switch day % 7 {
                case 0: text = "INR \(amount) refunded from Willow Books on \(date). Ref \(reference)."
                case 1: text = "INR \(amount) debited to Own savings account on \(date). Self transfer. Ref \(reference)."
                case 2: text = "INR \(amount) credited from Fictional Payroll on \(date). Ref \(reference)."
                case 3: text = "INR \(amount) debited to Juniper Studio via UPI on \(date). Ref \(reference)."
                default:
                    let shop = shops[(month + day) % shops.count]
                    text = "INR \(amount) spent at \(shop) on \(date) using card XX0007. Ref \(reference)."
                }
                return make("activity-\(month)-\(day)", sender, text, month: month, day: day)
            }
        }
    }

    private static var reviewAndImportCases: [Message] {
        let delivery = "INR 73.45 spent at Fictional Duplicate Cafe on 13/10/26. Ref DEMOREDELIVERY."
        return [
            make("repeat-original", "AX-AXISBK", delivery, month: 10, day: 13),
            make("repeat-redelivery", "AX-AXISBK", delivery, month: 10, day: 13, minute: 2),
            make("other-bank-reference", "VM-ICICIB", delivery, month: 10, day: 13, minute: 3),
            make("unknown-type-a", "VM-ICICIB", "INR 222.30 debited to Juniper Studio via UPI on 14/10/26. Ref DEMOBATCHA.", month: 10, day: 14),
            make("unknown-type-b", "VM-ICICIB", "INR 223.40 debited to Juniper Studio via UPI on 14/10/26. Ref DEMOBATCHB.", month: 10, day: 14, minute: 1),
            make("unknown-direction", "JD-IDFCFB", "INR 68.10 debited and credited on 14/10/26. Ref DEMODIRECTION.", month: 10, day: 14, minute: 2),
            make("card-statement", "VM-ICICIB", "ICICI Bank Credit Card XX0007 Statement is sent to tester@example.test. Total of INR 321.00 or minimum of INR 32.10 is due by 28-OCT-26.", month: 10, day: 15),
            make("mandate-notice", "JD-IDFCFB", "Your account will be debited with INR 190.25 towards Example Telecom on 16/10/26.", month: 10, day: 15, minute: 1),
            make("mandate-payment", "JD-IDFCFB", "INR 190.25 paid at Example Telecom on 16/10/26. Ref DEMOMANDATE.", month: 10, day: 16),
            make("unparsed-balance", "AX-AXISBK", "Available balance INR 712.00 in A/c XX0007.", month: 10, day: 17),
            make("unparsed-empty", "VM-ICICIB", "", month: 10, day: 17, minute: 1),
            make("unrelated", "FICTIONAL-SENDER", "INR 17.00 spent at a fictional cafe.", month: 10, day: 17, minute: 2),
            make("refresh-purchase", "AX-AXISBK", "INR 175.85 spent at Fictional Orchard on 05/11/26. Ref DEMOREFRESHA.", month: 11, day: 5),
            make("refresh-transfer", "JD-IDFCFB", "INR 375.20 debited to Own savings account on 06/11/26. Self transfer. Ref DEMOREFRESHB.", month: 11, day: 6),
            make("refresh-refund", "VM-ICICIB", "INR 69.90 refunded from Fictional Orchard on 07/11/26. Ref DEMOREFRESHC.", month: 11, day: 7),
        ]
    }

    private static func make(_ id: String, _ sender: String, _ text: String, month: Int, day: Int, minute: Int = 0) -> Message {
        let received = TransactionRecord.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12, minute: minute))!
        return Message(guid: "ledger-demo-v2-\(id)", sender: sender, text: text, receivedAt: received, service: "SMS", isFromMe: false)
    }
}
