import SwiftUI
import LedgerCore

struct LedgerTransactionInspector: View {
    @ObservedObject var draft: TransactionDraft
    @ObservedObject var model: TransactionsModel
    let save: () async -> Bool
    let close: () -> Void
    let delete: () -> Void
    let unlink: (TransactionRecord) -> Void
    @State private var expanded = false
    @State private var source: SourcePresentation?
    @State private var linkedSources: [SourcePresentation]?
    @FocusState private var focus: TransactionDraft.Field?

    var body: some View {
        if let record = draft.baseline {
            VStack(spacing: 0) {
                HStack {
                    Text(draft.editing ? "Edit transaction" : "Transaction details").font(.caption).foregroundStyle(LedgerStyle.muted)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(LedgerPlainButton())
                        .accessibilityLabel("Return to list").disabled(model.busy)
                }.padding(18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: record.category.symbol).font(.system(size: 23))
                            .foregroundStyle(LedgerStyle.accent).padding(13)
                            .background(LedgerStyle.selection, in: RoundedRectangle(cornerRadius: 12))
                        Button { draft.begin(.merchant) } label: {
                            Text(record.merchant).font(LedgerStyle.section).multilineTextAlignment(.leading)
                        }.buttonStyle(LedgerPlainButton()).accessibilityLabel("Edit merchant: \(record.merchant)")
                        Button { draft.begin(.amount) } label: {
                            Text(record.formattedAmount).font(.system(size: 32, weight: .medium, design: .serif)).monospacedDigit()
                        }.buttonStyle(LedgerPlainButton()).accessibilityLabel("Edit amount: \(record.formattedAmount)")
                        if record.needsReview {
                            LedgerNotice(title: "Needs Review · Excluded from spending", detail: record.reviewExplanation)
                        }
                        if record.linkedCardPaymentID != nil {
                            LedgerNotice(title: "Two receipts · One card payment")
                        }
                        if draft.editing {
                            editForm
                        } else {
                            VStack(spacing: 15) {
                                readField("Date", value: record.date.formatted(TransactionRecord.dateStyle.year()), field: .date)
                                readField("Bank", value: record.bank.rawValue, field: .bank)
                                readField("Direction", value: record.direction.label, field: .direction)
                                    .disabled(record.linkedCardPaymentID != nil)
                                readField("Type", value: record.type.label, field: .type)
                                    .disabled(record.linkedCardPaymentID != nil)
                                readField("Category", value: record.category.displayName, field: .category)
                            }
                            Text("Click a field to edit it.").font(.caption).foregroundStyle(LedgerStyle.muted)
                        }
                        Rectangle().fill(LedgerStyle.line).frame(height: 1)
                        DisclosureGroup(record.linkedCardPaymentID != nil ? "Original SMS · 2 linked receipts" :
                                            (model.demo ? "Original SMS · Fictional" : "Original SMS"), isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: 10) {
                                if record.linkedCardPaymentID != nil, let linkedSources {
                                    if linkedSources.isEmpty { Text("Linked receipts unavailable.") }
                                    ForEach(linkedSources.indices, id: \.self) { index in
                                        let receipt = linkedSources[index]
                                        if index > 0 { Divider() }
                                        Text(receipt.bank?.rawValue ?? "Receipt \(index + 1)").fontWeight(.medium)
                                        originalSMS(receipt)
                                    }
                                } else if let source {
                                    originalSMS(source)
                                } else { ProgressView("Fetching original locally…").controlSize(.small) }
                            }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(LedgerStyle.canvas, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 8)
                        }.font(.callout)
                        if let parsed = source?.parsed, let value = draft.record,
                           (parsed.merchant != nil && parsed.merchant != value.merchant) ||
                           (parsed.type != .uncertain && parsed.type != value.type) ||
                           (parsed.direction != .uncertain && parsed.direction != value.direction) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Suggested from original SMS").font(.callout.weight(.medium))
                                Text("\(parsed.merchant ?? value.merchant) · \(parsed.direction.label) · \(parsed.type.label)")
                                    .font(.caption).foregroundStyle(LedgerStyle.muted)
                                Button("Use suggested details") {
                                    draft.begin(.merchant)
                                    var updated = value
                                    if let merchant = parsed.merchant { updated.merchant = merchant }
                                    if parsed.type != .uncertain { updated.type = parsed.type }
                                    if parsed.direction != .uncertain { updated.direction = parsed.direction }
                                    draft.record = updated; draft.remember = false
                                }.disabled(model.busy)
                                Text("Fills the draft only. Save to keep the changes.").font(.caption).foregroundStyle(LedgerStyle.muted)
                            }
                        }
                        DisclosureGroup("About this record") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.manuallyEdited ? "Saved correction · Protected on reimport" : record.dateFromSMS ? "Date read from SMS" : "Date uses message receipt time")
                                if record.recipientTypeRuleKey != nil {
                                    Text("Payment type from your remembered recipient choice. Manage it in Merchant rules. An individual saved edit takes priority.")
                                }
                                Text("Dates use Asia/Kolkata. Full SMS is retrieved only on demand and is never stored in Ledger’s database.")
                                Text("A category describes purpose. Direction and type decide whether a record can count as confirmed spending.")
                            }.font(.caption).foregroundStyle(LedgerStyle.muted).padding(.top, 10)
                        }.font(.caption).foregroundStyle(LedgerStyle.muted)
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                Rectangle().fill(LedgerStyle.line).frame(height: 1)
                actions
            }
            .disclosureGroupStyle(LedgerDisclosureStyle())
            .disabled(model.busy)
            .onAppear { expanded = record.needsReview }
            .task(id: expanded ? (record.linkedCardPaymentID ?? record.id) : nil) {
                source = nil
                linkedSources = nil
                if expanded {
                    if record.linkedCardPaymentID != nil {
                        let receipts = await model.linkedOriginals(id: record.id)
                        if !Task.isCancelled { linkedSources = receipts }
                    } else {
                        let presentation = await model.original(id: record.id)
                        if !Task.isCancelled { source = presentation }
                    }
                }
            }
            .onChange(of: draft.focus) { _, value in focus = value }
            .onChange(of: draft.editing) { _, editing in if !editing { focus = nil } }
        }
    }

    @ViewBuilder private func originalSMS(_ source: SourcePresentation) -> some View {
        if let receiptLabel = source.receiptLabel {
            Text(receiptLabel).font(.caption).foregroundStyle(LedgerStyle.muted).textSelection(.enabled)
        }
        Text(source.text ?? "Original SMS unavailable").textSelection(.enabled)
        Text(source.explanation).foregroundStyle(LedgerStyle.muted)
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            editField("Merchant or recipient") {
                TextField("Merchant or recipient", text: value(\.merchant, fallback: "")).focused($focus, equals: .merchant)
            }
            editField("Amount (INR)") { TextField("0.00", text: $draft.amount).monospacedDigit().focused($focus, equals: .amount) }
            editField("Date · Asia/Kolkata") {
                DatePicker("Date", selection: value(\.date, fallback: Importer.start), displayedComponents: .date).labelsHidden()
                    .environment(\.timeZone, Importer.timeZone).focused($focus, equals: .date)
            }
            LedgerSelect("Bank", selection: value(\.bank, fallback: Bank.axis), options: Bank.allCases) { $0.rawValue }
                .focused($focus, equals: .bank)
            LedgerSelect("Direction", selection: value(\.direction, fallback: Direction.uncertain), options: Direction.allCases) { $0.label }
                .focused($focus, equals: .direction).disabled(draft.baseline?.linkedCardPaymentID != nil)
            LedgerSelect("Type", selection: value(\.type, fallback: TransactionType.uncertain), options: TransactionType.allCases) { $0.label }
                .focused($focus, equals: .type).disabled(draft.baseline?.linkedCardPaymentID != nil)
            LedgerSelect("Category", selection: value(\.category, fallback: SpendingCategory.uncategorized), options: SpendingCategory.allCases) { $0.displayName }
                .focused($focus, equals: .category)
            if let record = draft.record {
                if record.category == .incomeSalary {
                    Text("Income / Salary is for money coming in. Set Direction to Money in and Type to Incoming payment or Transfer to include it in the income total. Choosing this category alone does not resolve Needs Review.")
                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                }
                if record.category == .uncategorized,
                   let decision = CategorizationPipeline(rules: model.rules).decision(merchant: record.merchant, direction: record.direction, type: record.type),
                   decision.category != record.category {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(decision.reason).font(.caption).foregroundStyle(LedgerStyle.muted)
                        Button("Use \(decision.category.label)") { value(\.category, fallback: SpendingCategory.uncategorized).wrappedValue = decision.category }
                    }
                }
                if draft.canRemember {
                    Toggle("Always use \(record.category.displayName) for \(MerchantIntelligence.canonicalName(record.merchant))", isOn: $draft.remember)
                        .toggleStyle(.checkbox).ledgerClickableCursor().font(.callout)
                    Text("Remembers a local merchant rule for future reliable matches. Existing saved choices take priority.")
                        .font(.caption).foregroundStyle(LedgerStyle.muted)
                }
                if let rule = model.rules.first(where: { $0.id == MerchantIntelligence.ruleKey(for: record.merchant) }) {
                    Text("Merchant rule: \(rule.category.label). Manage it in Merchant rules.").font(.caption).foregroundStyle(LedgerStyle.muted)
                }
                if record.needsReview {
                    Text("This stays Needs Review until direction and type are resolved. Assigning a category alone does not confirm spending.")
                        .font(.caption).foregroundStyle(LedgerStyle.warning)
                }
            }
            if draft.correction == nil {
                Text(draft.record?.category == .incomeSalary
                    ? "Income / Salary requires money in and an incoming payment or transfer. Check the direction, type, merchant and positive amount."
                    : "Enter a merchant, a positive amount with up to two decimals, and a direction consistent with the type.")
                    .font(.caption).foregroundStyle(LedgerStyle.danger)
            }
        }.textFieldStyle(LedgerTextFieldStyle())
        .task {
            // Focus after the native form controls have joined the view tree.
            await Task.yield()
            focus = draft.focus
        }
    }
    private var actions: some View {
        HStack(spacing: 12) {
            if draft.editing {
                Button("Cancel") { draft.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(draft.dirty ? "Unsaved" : "No changes").font(.caption).foregroundStyle(LedgerStyle.muted)
                Button("Save") { Task { _ = await save() } }.buttonStyle(LedgerPrimaryButton())
                    .disabled(!draft.dirty || draft.correction == nil).keyboardShortcut("s", modifiers: .command)
            } else if let record = draft.baseline, record.linkedCardPaymentID != nil {
                Button("Unlink payment") { unlink(record) }
                    .help("Show both records separately with their saved details.")
                Spacer()
                Text("Saved locally").font(.caption).foregroundStyle(LedgerStyle.muted)
            } else {
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(LedgerPlainButton()).foregroundStyle(LedgerStyle.danger)
                    .help("Remove from Ledger. Undo is available until this app quits. The original SMS stays untouched.")
                Spacer()
                Text("Saved locally").font(.caption).foregroundStyle(LedgerStyle.muted)
            }
        }.padding(16)
    }
    private func readField(_ title: String, value: String, field: TransactionDraft.Field) -> some View {
        Button { draft.begin(field) } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(LedgerStyle.muted)
                Spacer(minLength: 14)
                Text(value).multilineTextAlignment(.trailing)
            }.font(.callout).contentShape(Rectangle())
        }.buttonStyle(LedgerPlainButton()).accessibilityLabel("Edit \(title): \(value)")
    }
    private func editField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(LedgerStyle.muted); content() }
    }
    private func value<T>(_ key: WritableKeyPath<TransactionRecord, T>, fallback: T) -> Binding<T> {
        // Native controls may finish updating a binding after its old selection
        // was cleared. Never force-unwrap a draft during that teardown.
        Binding(get: { draft.record?[keyPath: key] ?? fallback }, set: { next in
            guard var updated = draft.record else { return }
            updated[keyPath: key] = next
            draft.record = updated; draft.remember = false
        })
    }
}
