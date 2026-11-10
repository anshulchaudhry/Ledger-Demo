import SwiftUI
import LedgerCore

struct MerchantRulesView: View {
    @ObservedObject var model: TransactionsModel
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let knownTypes = RecipientReview.knownTypes(records: model.transactions)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Merchant rules").font(LedgerStyle.title)
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.busy) }
            }
            Text("Category rules describe purpose. Remembered recipient choices separately identify a payment as an Expense, Transfer or Card payment.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            Text("Changing or removing a rule leaves existing payments unchanged. New uncertain money-out payments can reuse a remembered type only for an exact recipient match within its bank.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Category rules").font(LedgerStyle.section)
                    if model.rules.isEmpty {
                        Text("No saved category rules. Choose a category in a transaction and enable Always use this category before saving.")
                            .font(.callout).foregroundStyle(LedgerStyle.muted)
                    }
                        ForEach(model.rules) { rule in
                            MerchantRuleRow(rule: rule, busy: model.busy,
                                save: { await model.saveMerchantRule($0) },
                                remove: { await model.removeMerchantRule(id: rule.id) })
                                .id(rule.id + "|" + rule.category.rawValue)
                                .ledgerCard(padding: 16)
                        }
                    Text("Remembered payment types").font(LedgerStyle.section).padding(.top, 12)
                    Text("Create these in Needs Review → Review by recipient. Only new imports receive the remembered type; existing review records require your selected-row approval. Exact saved category rules take priority over a remembered purpose category.")
                        .font(.callout).foregroundStyle(LedgerStyle.muted)
                    if model.recipientRules.isEmpty {
                        Text("No remembered payment types yet.").foregroundStyle(LedgerStyle.muted)
                    }
                    ForEach(model.recipientRules) { rule in
                        RecipientTypeRuleRow(rule: rule, busy: model.busy,
                            knownTypes: knownTypes[rule.id] ?? [],
                            save: { await model.updateRecipientRule($0, previous: rule) },
                            remove: { await model.removeRecipientRule(rule) })
                            .id(rule.id + "|" + rule.type.rawValue + "|" + (rule.category?.rawValue ?? ""))
                            .ledgerCard(padding: 16)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(model.demo ? "Fictional Demo rules only · Saved locally" : "Saved locally · No Messages access needed to manage rules")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
        }
        .padding(28).frame(width: embedded ? nil : 660, height: embedded ? nil : 460)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(LedgerStyle.canvas)
        .alert("Ledger", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct RecipientTypeRuleRow: View {
    let rule: RecipientTypeRule
    let busy: Bool
    let knownTypes: Set<TransactionType>
    let save: (RecipientTypeRule) async -> Bool
    let remove: () async -> Void
    @State private var type: TransactionType
    @State private var category: SpendingCategory?
    @State private var removing = false
    private var conflict: Bool { knownTypes.contains { $0 != type } }
    init(rule: RecipientTypeRule, busy: Bool, knownTypes: Set<TransactionType>,
         save: @escaping (RecipientTypeRule) async -> Bool, remove: @escaping () async -> Void) {
        self.rule = rule; self.busy = busy; self.knownTypes = knownTypes; self.save = save; self.remove = remove
        _type = State(initialValue: rule.type); _category = State(initialValue: rule.category)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.recipient).font(.headline)
                    Text("\(rule.bank.rawValue) · Exact saved recipient name").font(.caption).foregroundStyle(LedgerStyle.muted)
                }
                Spacer(); Button("Remove…", role: .destructive) { removing = true }
            }
            HStack(alignment: .top, spacing: 16) {
                LedgerSelect("Payment type", selection: $type, options: RecipientTypeRule.allowedTypes) { $0.label }.frame(width: 220)
                if type == .expense {
                    LedgerSelect("New expense category", selection: $category,
                        options: [nil] + SpendingCategory.expenseCategories.map(Optional.some)) {
                        $0?.displayName ?? "Use category rules"
                    }.frame(width: 250)
                }
                Spacer()
            }
            if conflict {
                Text("Confirmed payments here use a different type. Automatic use is blocked while that conflict remains; review those payments or remove this rule.")
                    .font(.caption).foregroundStyle(LedgerStyle.warning)
            }
            Button("Save recipient rule") {
                var updated = rule
                updated.type = type; updated.category = type == .expense ? category : nil
                Task { _ = await save(updated) }
            }.disabled(conflict || (type == rule.type && (type == .expense ? category : nil) == rule.category))
        }.disabled(busy)
            .onChange(of: type) { _, value in if value != .expense { category = nil } }
            .confirmationDialog("Remove the remembered payment type for \(rule.recipient)?", isPresented: $removing) {
                Button("Remove rule", role: .destructive) { Task { await remove() } }
            } message: { Text("New imports will stop using it. Existing payments and saved corrections stay unchanged.") }
    }
}

private struct MerchantRuleRow: View {
    let rule: MerchantCategoryRule
    let busy: Bool
    let save: (MerchantCategoryRule) async -> Bool
    let remove: () async -> Void
    @State private var category: SpendingCategory
    @State private var confirmingRemoval = false

    init(rule: MerchantCategoryRule, busy: Bool, save: @escaping (MerchantCategoryRule) async -> Bool,
         remove: @escaping () async -> Void) {
        self.rule = rule
        self.busy = busy
        self.save = save
        self.remove = remove
        _category = State(initialValue: rule.category)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rule.merchant).fontWeight(.medium)
                Spacer()
                Button("Remove…", role: .destructive) { confirmingRemoval = true }.disabled(busy)
            }
            HStack {
                LedgerSelect("Category", selection: $category,
                    options: SpendingCategory.expenseCategories) { $0.displayName }
                    .frame(width: 300).disabled(busy)
                Button("Save rule") {
                    var updated = rule
                    updated.category = category
                    Task { _ = await save(updated) }
                }.disabled(busy || category == rule.category)
            }
        }.padding(.vertical, 8)
        .confirmationDialog("Remove the category rule for \(rule.merchant)?", isPresented: $confirmingRemoval) {
            Button("Remove rule", role: .destructive) { Task { await remove() } }
        } message: { Text("Future imports will stop using it. Existing transaction categories will stay as they are.") }
    }
}
