import SwiftUI
import LedgerCore

struct RecipientReviewView: View {
    @ObservedObject var model: TransactionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var group: RecipientReview.Group?
    @State private var selected = Set<String>()
    @State private var type: TransactionType = .expense
    @State private var typeChosen = false
    @State private var category: SpendingCategory?
    @State private var remember = false
    @State private var previewing = false
    @State private var original: OriginalTarget?
    private struct OriginalTarget: Identifiable { let id: String }

    private var plan: RecipientReview.Plan? {
        group.map { .init(group: $0, selectedIDs: selected, type: type, category: type == .expense ? category : nil, remember: remember) }
    }
    private func refresh() async {
        group = nil; selected = []; remember = false; previewing = false
        await model.loadRecipientGroups()
    }
    private func choose(_ value: RecipientReview.Group) {
        group = value
        selected = Set(value.records.filter { !$0.manuallyEdited }.map(\.id))
        type = value.remembered?.type ?? .expense
        typeChosen = value.remembered != nil
        category = value.remembered?.category
        remember = false; previewing = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(previewing ? "Preview payment changes" : "Review by recipient").font(LedgerStyle.title)
                Spacer()
                Button("Cancel") { dismiss() }.disabled(model.busy)
            }
            if let group, let plan {
                if previewing { preview(group, plan: plan) }
                else { selection(group, plan: plan) }
            } else { groups }
        }.padding(24).frame(width: 820, height: 680)
            .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.canvas)
            .buttonStyle(LedgerSecondaryButton())
            .interactiveDismissDisabled(model.busy)
            .task { await refresh() }
            .onChange(of: type) { _, value in
                if value != .expense { category = nil }
                if group?.canRemember(value) != true { remember = false }
            }
            .sheet(item: $original) { target in RecipientOriginalView(model: model, id: target.id) }
            .alert("Ledger", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
                Button("Refresh review") { model.error = nil; Task { await refresh() } }
            } message: { Text(model.error ?? "") }
    }

    private var groups: some View {
        let groupedCount = model.recipientGroups.reduce(0) { $0 + $1.count }
        let individual = model.transactions.filter(\.needsReview).count - groupedCount
        return VStack(alignment: .leading, spacing: 14) {
            Text("Confirm selected money-out payments together. Groups use the same saved recipient name within one bank. No similar-name guesses.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            Text("\(groupedCount) can be grouped · \(max(0, individual)) need individual checking")
                .font(.callout)
            if model.busy { ProgressView("Preparing recipient groups…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.recipientGroups.isEmpty {
                ContentUnavailableView("No eligible recipient groups", systemImage: "person.crop.rectangle.stack",
                    description: Text("Payments with unclear direction, no usable recipient or an already confirmed type stay outside this flow. Review them in the transaction list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.recipientGroups) { value in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(value.recipient).font(.headline)
                                    Text("\(value.bank.rawValue) · \(value.count) \(value.count == 1 ? "payment" : "payments") · \(value.records.filter(\.manuallyEdited).count) saved edits")
                                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                                    if !value.knownTypes.isEmpty {
                                        Text("Already confirmed here: " + RecipientTypeRule.allowedTypes.filter { value.knownTypes.contains($0) }.map(\.label).joined(separator: ", "))
                                            .font(.caption).foregroundStyle(LedgerStyle.muted)
                                    }
                                }
                                Spacer()
                                Button("Review \(value.count)") { choose(value) }
                                    .accessibilityLabel("Review \(value.count) \(value.count == 1 ? "payment" : "payments") to \(value.recipient), \(value.bank.rawValue)")
                            }.ledgerCard(padding: 16)
                        }
                    }
                }
            }
            HStack {
                Text("Saved records only · No Messages access needed to group payments").font(.caption).foregroundStyle(LedgerStyle.muted)
                Spacer()
                Button("Refresh groups") { Task { await refresh() } }.disabled(model.busy)
            }
        }
    }

    private func heading(_ group: RecipientReview.Group) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.recipient).font(LedgerStyle.section)
            Text("\(group.bank.rawValue) · Exact saved name · Money out only")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
        }
    }
    private func selection(_ group: RecipientReview.Group, plan: RecipientReview.Plan) -> some View {
        let typeSelection = Binding<TransactionType?>(get: { typeChosen ? type : nil }, set: { value in
            if let value { type = value; typeChosen = true }
            else { typeChosen = false; remember = false; category = nil }
        })
        return VStack(alignment: .leading, spacing: 12) {
            heading(group)
            HStack(alignment: .top, spacing: 20) {
                LedgerSelect("Payment type", selection: typeSelection,
                    options: [nil] + RecipientTypeRule.allowedTypes.map(Optional.some)) { $0?.label ?? "Choose payment type" }
                    .frame(width: 240)
                if typeChosen && type == .expense {
                    LedgerSelect("Fill Miscellaneous categories", selection: $category,
                        options: [nil] + SpendingCategory.expenseCategories.map(Optional.some)) {
                        $0?.displayName ?? "Keep current categories"
                    }.frame(width: 290)
                }
            }
            Text("Assigned categories, names, amounts and dates stay as saved. Previously edited payments start unchecked. Open Original SMS to check a payment. Existing merchant category rules take priority on future imports.")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
            HStack {
                Button("Select untouched") { selected = Set(group.records.filter { !$0.manuallyEdited }.map(\.id)) }
                Button("Clear selection") { selected = [] }
                Spacer()
                Button("Other recipients") { self.group = nil }
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(group.records) { record in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { checked in
                                if checked { selected.insert(record.id) } else { selected.remove(record.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(record.formattedAmount) · \(record.date.formatted(TransactionRecord.dateStyle.year()))").fontWeight(.medium)
                                    Text("\(record.category.displayName)" + (record.manuallyEdited ? " · Saved edit: include explicitly" : ""))
                                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.toggleStyle(.checkbox).ledgerClickableCursor()
                            Button("Original SMS") { original = OriginalTarget(id: record.id) }
                                .accessibilityLabel("Original SMS for \(record.merchant), \(record.formattedAmount), \(record.date.formatted(TransactionRecord.dateStyle))")
                        }.ledgerCard(padding: 12)
                    }
                }
            }
            if typeChosen && !group.canRemember(type) {
                Text("Other confirmed payments to this recipient use a different type. You can confirm selected payments, but cannot remember an automatic choice for this mixed group.")
                    .font(.caption).foregroundStyle(LedgerStyle.warning)
            }
            if let saved = group.remembered {
                Text("Existing remembered choice: \(saved.type.label). Remembering below updates that choice; leaving it off keeps the existing rule.")
                    .font(.caption).foregroundStyle(LedgerStyle.muted)
            }
            Toggle(typeChosen ? "Remember \(type.label)\(type == .expense ? category.map { " · " + $0.displayName } ?? "" : "") for new exact matches from \(group.bank.rawValue)" : "Remember the selected type for future exact matches", isOn: $remember)
                .toggleStyle(.checkbox).ledgerClickableCursor().disabled(!typeChosen || !group.canRemember(type) || selected.isEmpty)
            HStack {
                Text("\(selected.count) selected · " + (typeChosen ? "Nothing saved yet" : "Choose a payment type")).font(.caption).foregroundStyle(LedgerStyle.muted)
                Spacer()
                Button("Preview \(selected.count) \(selected.count == 1 ? "payment" : "payments")") { previewing = true }
                    .buttonStyle(LedgerPrimaryButton()).disabled(!typeChosen || selected.isEmpty || plan.amountPaise == nil)
            }
        }.disabled(model.busy)
    }

    private func preview(_ group: RecipientReview.Group, plan: RecipientReview.Plan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(group)
            if let amount = plan.amountPaise {
                let formatted = (Decimal(amount) / 100).formatted(.currency(code: "INR"))
                LedgerNotice(title: type == .expense ? "\(formatted) will enter confirmed spending." : "\(formatted) will stay outside spending.",
                    detail: "\(plan.selected.count) selected \(plan.selected.count == 1 ? "payment" : "payments") will leave Needs Review as \(type.label). Saved dates determine their months. Unselected payments stay unchanged.")
            }
            Text(remember ? "New exact money-out matches from \(group.bank.rawValue) will use \(type.label)\(plan.category.map { " · " + $0.displayName } ?? "") during manual imports. Existing merchant category rules take priority. Refunds, incoming payments, known types and uncertain matches stay protected." : "No new recipient rule will be created.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.proposed) { proposed in
                        let before = group.records.first { $0.id == proposed.id }!
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(proposed.formattedAmount) · \(proposed.date.formatted(TransactionRecord.dateStyle.year()))").fontWeight(.medium)
                            Text("Uncertain → \(proposed.type.label)")
                            Text(before.category == proposed.category ? "Category kept: \(before.category.displayName)" : "\(before.category.displayName) → \(proposed.category.displayName)")
                                .font(.caption).foregroundStyle(LedgerStyle.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).ledgerCard(padding: 12)
                    }
                }
            }
            HStack {
                Button("Back") { previewing = false }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(remember ? "Confirm \(selected.count) and remember" : "Confirm \(selected.count) \(selected.count == 1 ? "payment" : "payments")") {
                    Task { if await model.applyRecipientReview(plan) { self.group = nil; selected = []; previewing = false; remember = false } }
                }.buttonStyle(LedgerPrimaryButton()).disabled(model.busy)
            }
        }
    }
}

private struct RecipientOriginalView: View {
    @ObservedObject var model: TransactionsModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var source: SourcePresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.demo ? "Original SMS · Fictional" : "Original SMS").font(LedgerStyle.section)
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let source {
                if let receiptLabel = source.receiptLabel {
                    Text(receiptLabel).font(.caption).foregroundStyle(LedgerStyle.muted).textSelection(.enabled)
                }
                ScrollView { Text(source.text ?? "Original SMS unavailable").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                Text(source.explanation).font(.caption).foregroundStyle(LedgerStyle.muted)
            } else { ProgressView("Fetching original locally…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(24).frame(width: 620, height: 360)
            .background(LedgerStyle.canvas).foregroundStyle(LedgerStyle.ink).buttonStyle(LedgerSecondaryButton())
            .task { let result = await model.original(id: id); if !Task.isCancelled { source = result } }
    }
}
