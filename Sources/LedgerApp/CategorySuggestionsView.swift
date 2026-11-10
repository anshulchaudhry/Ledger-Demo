import SwiftUI
import LedgerCore

struct CategorySuggestionsView: View {
    @ObservedObject var model: TransactionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var rememberMerchants = false

    private var chosen: [CategorySuggestion] { model.categorySuggestions.filter { selected.contains($0.id) } }

    private func refresh() async {
        rememberMerchants = false
        await model.loadCategorySuggestions()
        selected = Set(model.categorySuggestions.filter { !$0.transaction.manuallyEdited }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Review category suggestions").font(LedgerStyle.section)
                Spacer()
                Button("Cancel") { dismiss() }.disabled(model.busy)
            }
            Text("Review recognized matches from your saved records. Only categories change when you apply them; assigned categories, transaction types and Needs Review records stay protected.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            Text("Previously edited records start unchecked. Select one explicitly to update its category.")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
            HStack {
                Button("Select all") { selected = Set(model.categorySuggestions.map(\.id)) }.disabled(model.busy)
                Button("Clear selection") { selected = [] }.disabled(model.busy)
                Spacer()
                Button("Refresh suggestions") { Task { await refresh() } }.disabled(model.busy)
            }
            if model.busy {
                ProgressView("Working locally…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.categorySuggestions.isEmpty {
                ContentUnavailableView("No recognized category suggestions", systemImage: "tag",
                    description: Text("Unknown merchants and Needs Review transactions need your input. Choose a category on an expense and remember a rule for future matches."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.categorySuggestions) { suggestion in
                            Toggle(isOn: Binding(get: { selected.contains(suggestion.id) }, set: { value in
                                if value { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(suggestion.transaction.merchant).fontWeight(.medium)
                                    Text("\(suggestion.transaction.bank.rawValue) · \(suggestion.transaction.formattedAmount) · \(suggestion.transaction.date.formatted(TransactionRecord.dateStyle))")
                                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                                    Text("\(suggestion.transaction.category.label) → \(suggestion.category.label)")
                                    Text(suggestion.source.rawValue + (suggestion.transaction.manuallyEdited ? " · Previously edited" : ""))
                                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox).ledgerClickableCursor().padding(12)
                            .background(LedgerStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Toggle("Remember selected merchant categories for future imports", isOn: $rememberMerchants)
                .toggleStyle(.checkbox).ledgerClickableCursor().disabled(model.busy || chosen.isEmpty)
            HStack {
                Text("\(chosen.count) selected · Local rules and merchant hints · No Messages access needed")
                    .font(.caption).foregroundStyle(LedgerStyle.muted)
                Spacer()
                Button("Apply \(chosen.count) \(chosen.count == 1 ? "suggestion" : "suggestions")") {
                    let batch = chosen
                    let remember = rememberMerchants
                    Task {
                        if await model.applyCategorySuggestions(batch, rememberMerchants: remember) { dismiss() }
                    }
                }.buttonStyle(LedgerPrimaryButton()).disabled(model.busy || chosen.isEmpty)
            }
        }
        .padding(24).frame(width: 760, height: 580)
        .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.canvas).tint(LedgerStyle.accent)
        .buttonStyle(LedgerSecondaryButton())
        .task { await refresh() }
        .alert("Ledger", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
