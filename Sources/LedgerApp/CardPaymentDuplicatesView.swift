import SwiftUI
import LedgerCore

struct CardPaymentDuplicatesView: View {
    @ObservedObject var model: TransactionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: [CardPaymentDuplicate] = []
    @State private var index = 0
    @State private var keepingID = ""
    @State private var scanning = true
    @State private var scanError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Possible duplicate card payments").font(LedgerStyle.section)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
            Text("Compare the debit and the card issuer’s receipt. Link a pair only if both SMS describe the same payment.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            if scanning {
                ProgressView("Checking linked SMS on this Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scanError {
                ContentUnavailableView("Could not check for duplicates", systemImage: "exclamationmark.triangle",
                                       description: Text(scanError)).frame(maxHeight: .infinity)
            } else if pairs.indices.contains(index) {
                comparison(pairs[index])
            } else {
                ContentUnavailableView("No possible duplicates to review", systemImage: "checkmark.circle",
                    description: Text("Ledger checks IDFC FIRST debits to CRED against Axis card payment receipts for the same amount received within 10 minutes."))
                    .frame(maxHeight: .infinity)
            }
            HStack {
                Button("Check again") { Task { await scan() } }.disabled(scanning || model.busy)
                Spacer()
                if !scanning, pairs.indices.contains(index) {
                    let pair = pairs[index]
                    Button("Link as one payment") {
                        let retained = keepingID
                        Task {
                            if await model.linkCardPayment(pair, keeping: retained) {
                                let linked = [pair.funding.record.id, pair.issuer.record.id]
                                pairs.removeAll { linked.contains($0.funding.record.id) || linked.contains($0.issuer.record.id) }
                                select(min(index, max(0, pairs.count - 1)))
                            }
                        }
                    }.buttonStyle(LedgerPrimaryButton()).disabled(model.busy || keepingID.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 820, height: 590)
        .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.canvas)
        .buttonStyle(LedgerSecondaryButton())
        .task { await scan() }
        .interactiveDismissDisabled(model.busy)
        .alert("Ledger", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func comparison(_ pair: CardPaymentDuplicate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pair \(index + 1) of \(pairs.count) · \(Int(pair.secondsApart.rounded())) seconds apart")
                    .font(.callout).foregroundStyle(LedgerStyle.muted)
                Spacer()
                Button("Previous") { select(index - 1) }.disabled(index == 0 || model.busy)
                Button("Next") { select(index + 1) }.disabled(index + 1 == pairs.count || model.busy)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    receipt(pair.funding, title: "Funding debit · IDFC FIRST")
                    receipt(pair.issuer, title: "Card receipt · Axis")
                }
            }
            Picker("Keep transaction details from", selection: $keepingID) {
                Text("Funding debit").tag(pair.funding.record.id)
                Text("Card receipt").tag(pair.issuer.record.id)
            }.pickerStyle(.segmented).disabled(model.busy)
            Text("The chosen record counts once in Card payments and stays outside spending. Both originals stay available. Unlink to restore the two separate records with their saved details.")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
        }
    }

    private func receipt(_ receipt: CardPaymentDuplicate.Receipt, title: String) -> some View {
        let row = receipt.record
        let source = SourcePresentation(text: nil, explanation: "", receivedAt: receipt.message.receivedAt)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(row.formattedAmount).font(LedgerStyle.section)
            Text("Saved as \(row.merchant) · \(row.bank.rawValue) · \(row.date.formatted(TransactionRecord.dateStyle.year())) · \(row.category.displayName)")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
            if row.manuallyEdited { Text("Saved correction").font(.caption).foregroundStyle(LedgerStyle.accent) }
            Divider()
            Text(source.receiptLabel ?? "").font(.caption).foregroundStyle(LedgerStyle.muted)
            Text(receipt.message.text).font(.callout).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard(padding: 14)
    }

    private func select(_ index: Int) {
        self.index = index
        keepingID = pairs.indices.contains(index) ? pairs[index].preferredRecordID : ""
    }

    private func scan() async {
        scanning = true
        scanError = nil
        defer { scanning = false }
        do {
            pairs = try await model.cardPaymentDuplicates()
            select(0)
        } catch is CancellationError {
            return
        } catch {
            pairs = []
            scanError = TransactionsModel.explain(error)
        }
    }
}
