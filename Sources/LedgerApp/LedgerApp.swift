import SwiftUI
import AppKit
import LedgerCore

@main
struct LedgerApp: App {
    @NSApplicationDelegateAdaptor(LedgerLifecycle.self) private var lifecycle
    @StateObject private var model = TransactionsModel(demo: AppMode.demo)
    var body: some Scene {
        Window(AppMode.demo ? "Ledger — Demo" : "Ledger", id: "ledger") { LedgerWorkspace(model: model) }
            .defaultSize(width: 1240, height: 820)
            .commands {
                CommandGroup(after: .toolbar) {
                    if AppMode.demo {
                        Menu("Demo window size") {
                            Button("Compact") { NSApp.mainWindow?.setContentSize(NSSize(width: 980, height: 740)) }
                            Button("Standard") { NSApp.mainWindow?.setContentSize(NSSize(width: 1240, height: 820)) }
                        }
                        Menu("Demo appearance") {
                            Button("Follow System") { NSApp.appearance = nil }
                            Button("Warm Light") { NSApp.appearance = NSAppearance(named: .aqua) }
                            Button("Warm Dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                        }
                    }
                }
            }
    }
}

enum LedgerPage: String, CaseIterable {
    case monthly = "Monthly spending", transactions = "Transactions", categories = "Categories", review = "Needs Review"
    case rules = "Merchant rules", imports = "Import & status"
    var transactionPage: Bool { self == .transactions || self == .review }
}

struct LedgerWorkspace: View {
    @ObservedObject var model: TransactionsModel
    @StateObject private var draft = TransactionDraft()
    @State private var page: LedgerPage = .monthly
    @State private var selectedID: String?
    @State private var search = ""
    @State private var bank: Bank?
    @State private var category: SpendingCategory?
    @State private var type: TransactionType?
    @State private var dateMonth: LedgerMonth?
    @State private var monthlyScope: MonthlyTransactionFilter?
    @State private var merchantScope: CategorizationPipeline.UnknownMerchant?
    @State private var reviewScope: ReviewDiagnostics.Group?
    @State private var month = LedgerMonth(containing: Date())
    @State private var importFrom = ImportWindow.defaultStart
    @State private var importThrough: Date?
    @State private var showMore = false
    @State private var showFilters = false
    @State private var showSuggestions = false
    @State private var showReviewDiagnostics = false
    @State private var showRecipientReview = false
    @State private var showCardPaymentDuplicates = false
    @State private var pendingReviewGroup: ReviewDiagnostics.Group?
    @State private var narrowDetail = false
    @State private var viewportWidth: CGFloat = 1240
    @State private var sessionID = UUID()
    @FocusState private var focusList: Bool
    @FocusState private var focusSearch: Bool


    private var visible: [TransactionRecord] {
        model.transactions.filter {
            (page != .review || $0.needsReview) && (bank == nil || $0.bank == bank) &&
            (category == nil || $0.category == category) && (type == nil || $0.type == type) &&
            (dateMonth?.contains($0.date) ?? true) && (monthlyScope?.includes($0) ?? true) &&
            (merchantScope?.transactionIDs.contains($0.id) ?? true) &&
            (reviewScope?.includes($0) ?? true) &&
            (search.isEmpty || "\($0.merchant) \($0.bank.rawValue) \($0.type.label) \($0.category.label)".localizedCaseInsensitiveContains(search) ||
                ($0.category == .uncategorized && "Other / Uncategorized".localizedCaseInsensitiveContains(search)))
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private var filtered: Bool { !search.isEmpty || bank != nil || category != nil || type != nil || dateMonth != nil || monthlyScope != nil || merchantScope != nil || reviewScope != nil }
    private var months: [LedgerMonth] { Set(model.transactions.map { LedgerMonth(containing: $0.date) }).sorted(by: >) }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Rectangle().fill(LedgerStyle.line).frame(height: 1)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Keep the transaction scroll view alive across tabs.
                    transactions(wide: geometry.size.width >= 1100)
                        .opacity(page.transactionPage ? 1 : 0)
                        .allowsHitTesting(page.transactionPage).accessibilityHidden(!page.transactionPage)
                    if !page.transactionPage {
                        switch page {
                        case .monthly:
                            LedgerSpendingPage(model: model, month: $month, open: openMonth,
                                               showDataStatus: { request { page = .imports } })
                        case .categories:
                            LedgerCategoriesPage(model: model, review: openMerchant,
                                suggestions: { request { showSuggestions = true } })
                        case .rules: MerchantRulesView(model: model, embedded: true)
                        case .imports: importPage
                        default: EmptyView()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear { viewportWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in
                    viewportWidth = width
                    narrowDetail = width < 1100 && page.transactionPage && selectedID != nil
                }
                .sheet(isPresented: $narrowDetail, onDismiss: {
                    if viewportWidth < 1100 { request { select(nil) } }
                }) {
                    VStack(spacing: 0) {
                        HStack { Button("Back to list") { request { select(nil) } }; Spacer() }.padding(16)
                        inspector
                    }.frame(width: 460, height: 650).background(LedgerStyle.canvas)
                        .buttonStyle(LedgerSecondaryButton())
                        .interactiveDismissDisabled(draft.dirty || model.busy)
                        .alert("Ledger", isPresented: errorBinding(inSheet: true)) {
                            Button("OK") { model.error = nil }
                        } message: { Text(model.error ?? "") }
                }
            }
            footer
        }
        .foregroundStyle(LedgerStyle.ink).background(LedgerStyle.canvas).tint(LedgerStyle.accent)
        .buttonStyle(LedgerSecondaryButton())
        .disclosureGroupStyle(LedgerDisclosureStyle())
        .frame(minWidth: 920, minHeight: 650)
        .background(LedgerWindowGuard(draft: draft).frame(width: 0, height: 0))
        .onAppear { LedgerLifecycle.sessions[sessionID] = draft }
        .onDisappear { LedgerLifecycle.sessions[sessionID] = nil }
        .task {
            await model.load()
            month = LedgerMonth(containing: model.transactions.map(\.date).max() ?? Date())
        }
        .sheet(isPresented: $showSuggestions) { CategorySuggestionsView(model: model).tint(LedgerStyle.accent) }
        .sheet(isPresented: $showRecipientReview) { RecipientReviewView(model: model).tint(LedgerStyle.accent) }
        .sheet(isPresented: $showCardPaymentDuplicates) { CardPaymentDuplicatesView(model: model).tint(LedgerStyle.accent) }
        .sheet(isPresented: $showReviewDiagnostics, onDismiss: {
            if let group = pendingReviewGroup {
                pendingReviewGroup = nil
                request { clearFilters(); page = .review; reviewScope = group; select(nil) }
            }
        }) {
            ReviewDiagnosticsView(model: model) { group in
                pendingReviewGroup = group
                showReviewDiagnostics = false
            }.tint(LedgerStyle.accent)
        }
        .alert("Ledger", isPresented: errorBinding(inSheet: false)) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }

    private func errorBinding(inSheet: Bool) -> Binding<Bool> {
        Binding(get: { model.error != nil && !showSuggestions && !showRecipientReview && !showCardPaymentDuplicates && page != .rules && narrowDetail == inSheet },
                set: { if !$0 { model.error = nil } })
    }

    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            navigationRow(compact: false)
            navigationRow(compact: true)
        }.padding(.horizontal, 22).padding(.vertical, 12).background(LedgerStyle.navigation)
    }
    private func navigationRow(compact: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Ledger").font(.system(size: 24, weight: .semibold, design: .serif)).fixedSize().padding(.trailing, 14)
            ForEach(Array(LedgerPage.allCases.prefix(4).enumerated()), id: \.element) { index, destination in
                Button { request {
                    if destination == .review && page != .review { clearFilters(); select(nil) }
                    page = destination
                } } label: {
                    HStack(spacing: 6) {
                        Text(destination.rawValue).fixedSize()
                        if destination == .review {
                            Text("\(model.transactions.filter(\.needsReview).count)").font(.caption.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(LedgerStyle.paper, in: Capsule()).foregroundStyle(LedgerStyle.muted)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .background(page == destination ? LedgerStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(LedgerPlainButton()).fixedSize().keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
            }
            Spacer(minLength: 8)
            if compact {
                Button { showMore.toggle() } label: { Label("More", systemImage: "ellipsis") }
                    .fixedSize().popover(isPresented: $showMore) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Merchant rules") { showMore = false; request { page = .rules } }
                            Button("Import & status") { showMore = false; request { page = .imports } }
                        }.padding(12).buttonStyle(LedgerSecondaryButton())
                            .background(LedgerStyle.paper).presentationBackground(LedgerStyle.paper)
                    }
            } else {
                ForEach([LedgerPage.rules, .imports], id: \.self) { destination in
                    Button(destination.rawValue) { request { page = destination } }.buttonStyle(LedgerPlainButton()).fixedSize()
                        .foregroundStyle(page == destination ? LedgerStyle.accent : LedgerStyle.muted)
                        .padding(.horizontal, 7).padding(.vertical, 8)
                        .background(page == destination ? LedgerStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func transactions(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(page == .review ? "Needs Review" : "Transactions").font(LedgerStyle.title)
                Spacer()
                if page == .transactions {
                    Button("Possible duplicates") { request { select(nil); showCardPaymentDuplicates = true } }
                        .disabled(model.busy)
                }
                TextField("Search transactions", text: guarded($search)).textFieldStyle(LedgerTextFieldStyle())
                    .frame(maxWidth: 280).focused($focusSearch)
                Button { request { focusSearch = true } } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(LedgerPlainButton()).keyboardShortcut("f", modifiers: .command).accessibilityLabel("Search transactions")
                Button { showFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                    .popover(isPresented: $showFilters) {
                        filters.padding(20).frame(width: 340).background(LedgerStyle.canvas)
                            .presentationBackground(LedgerStyle.canvas).buttonStyle(LedgerSecondaryButton())
                    }
            }
            if page == .review {
                HStack(alignment: .center, spacing: 16) {
                    LedgerNotice(title: "Check the direction and type before these count as spending.")
                    Spacer(minLength: 0)
                    Button("Review by recipient") { request { showRecipientReview = true } }.disabled(model.busy)
                    Button("Why these need review") { request { showReviewDiagnostics = true } }.disabled(model.busy)
                }
            } else if !filtered, model.transactions.contains(where: \.needsReview) {
                Button { request { page = .review } } label: {
                    HStack {
                        Text("\(model.transactions.filter(\.needsReview).count) transactions need review")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(12).background(LedgerStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(LedgerPlainButton()).foregroundStyle(LedgerStyle.muted)
            }
            if filtered {
                HStack(spacing: 12) {
                    Text(scopeLabel).font(.callout).lineLimit(2)
                    Spacer()
                    Button("Clear filters") { request { clearFilters(); select(nil) } }
                }.padding(10).background(LedgerStyle.selection, in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(alignment: .top, spacing: 20) {
                transactionList.frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide, selectedID != nil { inspector.frame(width: 350).ledgerCard(padding: 0) }
            }
        }.padding(24)
    }
    private var scopeLabel: String {
        [monthlyScope?.label, merchantScope.map { "Reviewing: \($0.merchant)" },
         reviewScope.map { "Reviewing: \($0.title)" }, bank?.rawValue, category?.displayName, type?.label, dateMonth?.label,
         search.isEmpty ? nil : "Search: \(search)"].compactMap { $0 }.joined(separator: " · ")
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filter transactions").font(.headline)
            LedgerSelect("Bank", selection: guarded($bank), options: [nil] + Bank.allCases.map(Optional.some)) { $0?.rawValue ?? "All banks" }
            LedgerSelect("Category", selection: guarded($category), options: [nil] + SpendingCategory.allCases.map(Optional.some)) { $0?.displayName ?? "All categories" }
            LedgerSelect("Type", selection: guarded($type), options: [nil] + TransactionType.allCases.map(Optional.some)) { $0?.label ?? "All types" }
            LedgerSelect("Date", selection: guarded($dateMonth), options: [nil] + months.map(Optional.some)) { $0?.label ?? "All dates" }
            HStack {
                Button("Reset") { request { clearFilters(); select(nil) } }
                Spacer(); Button("Done") { showFilters = false }.buttonStyle(LedgerPrimaryButton())
            }
        }.tint(LedgerStyle.accent)
    }
    private var transactionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if model.busy && model.transactions.isEmpty {
                        ProgressView("Opening your records…").frame(maxWidth: .infinity).padding(60)
                    } else if visible.isEmpty {
                        ContentUnavailableView(model.transactions.isEmpty ? "No transactions yet" : "No matching transactions", systemImage: "tray",
                            description: Text(model.transactions.isEmpty ? "Use Import & status to import your messages manually." : "Change your search or clear the filters."))
                        if filtered { Button("Clear filters") { request { clearFilters(); select(nil) } }.padding() }
                    } else {
                        let rows = visible
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index == 0 || !TransactionRecord.calendar.isDate(row.date, inSameDayAs: rows[index - 1].date) {
                                Text(row.date.formatted(TransactionRecord.dateStyle.year())).font(.caption)
                                    .foregroundStyle(LedgerStyle.muted).padding(.top, index == 0 ? 2 : 12).padding(.bottom, 3)
                            }
                            Button {
                                request { select(row.id); focusList = true }
                            } label: { LedgerTransactionRow(record: row, selected: row.id == selectedID) }
                                .buttonStyle(LedgerPlainButton()).id(row.id)
                                .accessibilityLabel("\(row.merchant), \(row.formattedAmount), \(row.category.label), \(row.type.label), \(row.bank.rawValue), \(row.date.formatted(TransactionRecord.dateStyle))\(row.needsReview ? ", Needs Review" : "")")
                                .accessibilityAddTraits(row.id == selectedID ? .isSelected : [])
                        }
                    }
                }.padding(.trailing, 4)
            }.focusable().focused($focusList).focusEffectDisabled()
                .onMoveCommand { direction in
                    guard page.transactionPage, direction == .up || direction == .down, !visible.isEmpty else { return }
                    let rows = visible
                    let current = rows.firstIndex(where: { $0.id == selectedID }) ?? (direction == .down ? -1 : rows.count)
                    let next = min(max(0, current + (direction == .down ? 1 : -1)), rows.count - 1)
                    request { select(rows[next].id); proxy.scrollTo(rows[next].id) }
                }
                .onExitCommand { request { select(nil) } }
        }
    }
    private var inspector: some View {
        LedgerTransactionInspector(draft: draft, model: model,
            save: { await saveDraft() }, close: { request { select(nil) } },
            delete: {
                request {
                    guard let id = selectedID else { return }
                    Task { if await model.delete(id: id) { select(nil) } }
                }
            }, unlink: { record in
                request {
                    guard let otherID = record.linkedCardPaymentID else { return }
                    Task { if await model.unlinkCardPayment(id: record.id, otherID: otherID) { select(record.id) } }
                }
            }).id(selectedID)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if let deleted = model.deletionHistory.last {
                Text("Deleted \(deleted.merchant)").lineLimit(1)
                Button("Undo deletion") {
                    request { Task {
                        if let restored = await model.undoDeletion() {
                            clearFilters(); page = .transactions; select(restored.id)
                        }
                    } }
                }.disabled(model.busy).keyboardShortcut(draft.editing ? nil : KeyboardShortcut("z", modifiers: .command))
                Text("Until app quits").foregroundStyle(LedgerStyle.muted)
            } else {
                Label(model.demo ? "Fictional Demo · No Messages access" : "Local & offline", systemImage: "circle.fill")
                    .foregroundStyle(LedgerStyle.muted)
                if !model.status.isEmpty { Text(model.status).lineLimit(1).foregroundStyle(LedgerStyle.muted) }
            }
            Spacer(minLength: 8)
            Text("Manual imports · INR · Asia/Kolkata").foregroundStyle(LedgerStyle.muted)
                .lineLimit(2)
        }.font(.caption).padding(.horizontal, 24).padding(.vertical, 11).background(LedgerStyle.navigation)
    }
    private var selectedImportWindow: ImportWindow? { ImportWindow(from: importFrom, through: importThrough ?? Date()) }

    private var importDateControls: some View {
        let today = TransactionRecord.calendar.startOfDay(for: Date())
        let through = Binding(get: { importThrough ?? today }, set: { importThrough = $0 })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                DatePicker("From", selection: $importFrom, in: ...today, displayedComponents: .date)
                DatePicker("Through", selection: through, in: ...today, displayedComponents: .date)
                Button("Use today") { importThrough = nil }.disabled(importThrough == nil)
            }
            Text(importThrough == nil ? "Through follows today in IST. Both dates are inclusive." : "Both receipt dates are inclusive, in IST.")
                .font(.callout).foregroundStyle(LedgerStyle.muted)
            if selectedImportWindow == nil {
                Text("Choose a From date on or before Through.").font(.callout).foregroundStyle(LedgerStyle.warning)
            }
        }.environment(\.calendar, TransactionRecord.calendar).environment(\.timeZone, Importer.timeZone)
            .disabled(model.busy)
    }

    private var importPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import & status").font(LedgerStyle.title)
                Text(model.demo ? "Explore Ledger with fictional examples." : "Read supported bank SMS already synced to this Mac.")
                    .foregroundStyle(LedgerStyle.muted)
                dataStatus
                VStack(alignment: .leading, spacing: 18) {
                    LabeledContent("Source", value: model.demo ? "Fictional examples" : "Apple Messages · Read only")
                    importDateControls
                    Button(model.demo ? "Import fictional examples" : "Import Messages") {
                        guard let window = selectedImportWindow else { return }
                        Task { await model.importMessages(window: window) }
                    }.buttonStyle(LedgerPrimaryButton()).disabled(model.busy || selectedImportWindow == nil)
                    if model.busy { ProgressView("Working locally…").controlSize(.small) }
                    if let scan = model.importHistory?.lastScan {
                        LabeledContent("Last successful scan", value: scan.scannedRangeLabel)
                        Text("Completed \(scan.completedAt.formatted(TransactionRecord.dateStyle.year().hour().minute())) (IST)")
                            .font(.caption).foregroundStyle(LedgerStyle.muted)
                        Text("\(scan.result.inserted) added · \(scan.result.updated) updated · \(scan.result.excluded) non-transactions excluded · \(scan.result.unparsed) unparsed candidates.")
                            .font(.callout).foregroundStyle(LedgerStyle.muted).textSelection(.enabled)
                    }
                }.ledgerCard()
                LedgerNotice(title: "Imports are manual. Monthly coverage is incomplete.",
                    detail: "The selected receipt dates apply to the next scan. Previously saved transactions stay available.")
                DisclosureGroup("Storage & privacy") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Saved records and merchant rules stay on this Mac. No cloud, analytics or bank credentials.")
                        Text("Full SMS is retrieved on demand and is not stored in Ledger’s database. Deleting from Ledger never deletes a message.")
                        Text("Undo deletion is available during this app session. Quitting clears its in-memory history; deletions that were not undone remain protected against reimport.")
                        Text("Local databases may be included in system backups. Ledger does not provide a backup service.")
                    }.font(.callout).foregroundStyle(LedgerStyle.muted).padding(.top, 10)
                }
            }.frame(maxWidth: 900, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dataStatus: some View {
        let windows = model.importHistory?.scannedWindows ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text("Data available").font(LedgerStyle.section)
            LabeledContent("Last refresh", value: model.lastRefreshLabel)
            LabeledContent("Saved transactions", value: "\(model.transactions.count)")
            if let dates = model.savedDateRangeLabel {
                LabeledContent("Saved transaction dates", value: dates)
            }
            Text("Recorded SMS receipt scans · IST").font(.callout.weight(.semibold))
            if windows.isEmpty {
                Text("No receipt scans recorded yet.").font(.callout).foregroundStyle(LedgerStyle.muted)
            } else {
                ForEach(windows.indices, id: \.self) { index in
                    Text(windows[index].scannedRangeLabel).font(.callout).textSelection(.enabled)
                }
            }
            Text("Saved transaction dates can differ from SMS receipt dates. A scanned range may still have missing or unrecognized messages.")
                .font(.caption).foregroundStyle(LedgerStyle.muted)
        }.ledgerCard()
    }

    private func select(_ id: String?) {
        selectedID = id
        narrowDetail = id != nil && viewportWidth < 1100
        draft.select(model.transactions.first { $0.id == id })
    }
    private func request(_ action: @escaping () -> Void) {
        guard !model.busy else { return }
        guard draft.dirty else { draft.cancel(); action(); return }
        // Finish the native alert before changing a detail sheet or its selection.
        // Changing both presentation layers in a SwiftUI dialog action can strand a sheet.
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Save your transaction or discard this draft before leaving it."
        let save = alert.addButton(withTitle: "Save and continue")
        save.isEnabled = draft.correction != nil
        alert.addButton(withTitle: "Discard changes")
        let keep = alert.addButton(withTitle: "Keep editing")
        keep.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { if await saveDraft() { action() } }
        case .alertSecondButtonReturn: draft.cancel(); action()
        default: break
        }
    }
    private func guarded<Value: Equatable>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { value in
            // SwiftUI can write back unchanged control values during a redraw.
            // Only an actual filter edit may navigate away from the draft.
            guard value != binding.wrappedValue else { return }
            request { binding.wrappedValue = value; select(nil) }
        })
    }
    private func clearFilters() { search = ""; bank = nil; category = nil; type = nil; dateMonth = nil; monthlyScope = nil; merchantScope = nil; reviewScope = nil }
    private func openMonth(_ filter: MonthlyTransactionFilter) {
        request { clearFilters(); page = .transactions; monthlyScope = filter; select(nil) }
    }
    private func openMerchant(_ group: CategorizationPipeline.UnknownMerchant) {
        request { clearFilters(); page = .transactions; merchantScope = group; select(nil) }
    }
    private func saveDraft() async -> Bool {
        guard let correction = draft.correction else { return false }
        draft.saving = true
        defer { draft.saving = false }
        let ok = await model.save(correction, rememberMerchantCategory: draft.remember && draft.canRemember)
        if ok {
            if visible.contains(where: { $0.id == correction.id }) { draft.select(model.transactions.first { $0.id == correction.id }) }
            else { select(nil) }
        }
        return ok
    }
}

struct LedgerTransactionRow: View {
    let record: TransactionRecord
    let selected: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: record.category.symbol).font(.system(size: 18)).foregroundStyle(LedgerStyle.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.merchant).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(record.bank.rawValue) · \(record.type.label)").font(.caption).foregroundStyle(LedgerStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(record.category.displayName).font(.callout).foregroundStyle(LedgerStyle.muted)
                .frame(width: 140, alignment: .leading).lineLimit(1)
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.formattedAmount).font(.callout.weight(.medium)).monospacedDigit()
                if record.needsReview { Text("Needs Review").font(.caption).foregroundStyle(LedgerStyle.muted) }
            }.frame(minWidth: 100, alignment: .trailing)
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .background(selected ? LedgerStyle.selection : LedgerStyle.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}
