import SwiftUI

enum ExpenseEditorMode {
    case actual
    case estimate
}

struct ExpenseEditorView: View {
    let trip: SharedTripSnapshot
    let existingExpense: ExpenseSnapshot?
    let members: [TripMemberSummary]
    let mode: ExpenseEditorMode
    let onSave: (ExpenseRequest, UUID) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var currency: String
    @State private var category: ExpenseCategory
    @State private var spentAt: Date
    @State private var purchaseChannel: String
    @State private var paymentMethod: String
    @State private var consumerUserID: Int?
    @State private var note: String
    @State private var cardIDs: [Int]
    /// 支付状态：已支出时 paidAt 为实际支付时间；未支出（如到店付）可留空
    /// 或设定预计支付时间，跨过该时刻后前端自动视为已支出。
    @State private var isPaid: Bool
    @State private var paidAtDate: Date
    @State private var hasExpectedPaidAt: Bool
    @State private var showsCardPicker = false
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var saveKey = UUID()
    @State private var lastSaveBody: Data?

    init(trip: SharedTripSnapshot, existingExpense: ExpenseSnapshot? = nil, members: [TripMemberSummary] = [], initialDate: Date? = nil, mode: ExpenseEditorMode = .actual, onSave: @escaping (ExpenseRequest, UUID) async -> String?) {
        self.trip = trip
        self.existingExpense = existingExpense
        self.members = members
        self.mode = existingExpense?.isEstimate == true ? .estimate : mode
        self.onSave = onSave
        let currency = existingExpense?.currency ?? trip.currency ?? "CNY"
        _currency = State(initialValue: currency)
        _amountText = State(initialValue: existingExpense.map { ExpenseMoney.inputString($0.amountMinor, currency: currency) } ?? "")
        _category = State(initialValue: existingExpense?.category ?? .other)
        _spentAt = State(initialValue: existingExpense?.spentAt ?? Self.date(from: existingExpense?.occurredOn) ?? initialDate ?? .now)
        _purchaseChannel = State(initialValue: existingExpense?.purchaseChannel ?? "")
        _paymentMethod = State(initialValue: existingExpense?.paymentMethod ?? "")
        _consumerUserID = State(initialValue: existingExpense?.consumerUserID)
        _note = State(initialValue: existingExpense?.note ?? "")
        _cardIDs = State(initialValue: existingExpense?.cardIDs ?? [])
        // 手动记一笔默认已支付（沿用旧行为）；仅未支付的单子保留预计支付时间。
        _isPaid = State(initialValue: existingExpense.map { $0.isPaid() } ?? mode == .actual)
        _paidAtDate = State(initialValue: existingExpense?.paidAt ?? .now)
        _hasExpectedPaidAt = State(initialValue: existingExpense?.paidAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(amountSectionKey) {
                    TextField("expenseeditor.amountPlaceholder", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("expenseeditor.currencyLabel", selection: $currency) {
                        ForEach(ExpenseCurrency.supported, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    Text(String(format: String(localized: "expenseeditor.conversionNote"), trip.currency ?? String(localized: "expenseeditor.currencyPending")))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("expenseeditor.categorySection") {
                    Picker("expenseeditor.categoryLabel", selection: $category) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                }
                Section {
                    if mode == .estimate {
                        Toggle("expenseeditor.expectedPaidAtToggle", isOn: $hasExpectedPaidAt)
                        if hasExpectedPaidAt {
                            DatePicker(
                                "expenseeditor.expectedPaidAt",
                                selection: $paidAtDate,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    } else {
                        Picker("expenseeditor.paymentStatus", selection: $isPaid) {
                            Text("expenseeditor.paid").tag(true)
                            Text("expenseeditor.unpaid").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if isPaid {
                            DatePicker(
                                "expenseeditor.paidAt",
                                selection: $paidAtDate,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        } else {
                            Toggle("expenseeditor.expectedPaidAtToggle", isOn: $hasExpectedPaidAt)
                            if hasExpectedPaidAt {
                                DatePicker(
                                    "expenseeditor.expectedPaidAt",
                                    selection: $paidAtDate,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                            }
                        }
                    }
                } header: {
                    Text(paymentSectionKey)
                } footer: {
                    Text(paymentHelpKey)
                }
                Section {
                    DatePicker(
                        spentAtKey,
                        selection: $spentAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    LabeledContent("expenseeditor.purchaseChannel") {
                        TextField("expenseeditor.purchaseChannelPlaceholder", text: $purchaseChannel)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("expenseeditor.paymentMethod", selection: $paymentMethod) {
                        Text("expenseeditor.notSpecified").tag("")
                        ForEach(ExpensePaymentMethod.allCases) { method in
                            Text(method.title).tag(method.rawValue)
                        }
                    }
                    if !members.isEmpty {
                        Picker("expenseeditor.consumer", selection: $consumerUserID) {
                            Text("expenseeditor.notSpecified").tag(Int?.none)
                            ForEach(members) { member in
                                Text(member.visibleName).tag(Optional(member.userId))
                            }
                        }
                    }
                    if let existingExpense {
                        LabeledContent("expenseeditor.createdAt") {
                            Text(Self.recordedFormatter.string(from: existingExpense.createdAt))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(transactionDetailsKey)
                } footer: {
                    Text(transactionDetailsHelpKey)
                }
                Section {
                    ForEach(cardIDs, id: \.self) { cardID in
                        if let card = allCards.first(where: { $0.serverID == cardID }) {
                            HStack(spacing: 12) {
                                Image(systemName: card.kind.systemImage)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(PrimaryTabPalette.accent)
                                    .frame(width: 38, height: 38)
                                    .background(PrimaryTabPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.title).lineLimit(1)
                                    Text(card.kind.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    cardIDs.removeAll { $0 == cardID }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(String(format: String(localized: "expenseeditor.unlinkCardA11y"), card.title)))
                            }
                        }
                    }

                    Button {
                        showsCardPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(cardIDs.isEmpty ? Color.secondary : PrimaryTabPalette.accent)
                                .frame(width: 38, height: 38)
                                .background(
                                    (cardIDs.isEmpty ? Color.secondary : PrimaryTabPalette.accent).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cardIDs.isEmpty
                                     ? String(localized: "expenseeditor.chooseCard")
                                     : String(format: String(localized: "expenseeditor.linkedCountFormat"), cardIDs.count))
                                    .foregroundStyle(.primary)
                                Text("expenseeditor.chooseCardHint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("expenseeditor.linkSection")
                } footer: {
                    Text(linkHelpKey)
                }
                Section {
                    TextField("expenseeditor.notePlaceholder", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("expenseeditor.noteSection")
                } footer: {
                    Text(noteHelpKey)
                }
                if let validationMessage { Text(validationMessage).foregroundStyle(.red) }
            }
            .navigationTitle(Text(navigationTitleKey))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if isSaving { ProgressView() } else { Text("common.save") }
                    }
                    .disabled(trip.currency == nil || isSaving)
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .alert("agent.cannotCompleteTitle", isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )) {
                Button("common.done") { validationMessage = nil }
            } message: { Text(validationMessage ?? "") }
            .sheet(isPresented: $showsCardPicker) {
                ExpenseCardLinkPicker(
                    trip: trip,
                    selectedCardIDs: cardIDs
                ) { toggledID in
                    if let index = cardIDs.firstIndex(of: toggledID) {
                        cardIDs.remove(at: index)
                    } else {
                        cardIDs.append(toggledID)
                    }
                }
            }
        }
    }

    private var allCards: [TravelCardSnapshot] {
        trip.days.flatMap(\.cards).filter { $0.serverID != nil }.sorted { $0.title < $1.title }
    }

    private var navigationTitleKey: LocalizedStringKey {
        if mode == .estimate {
            return existingExpense == nil ? "expenseestimate.addTitle" : "expenseestimate.editTitle"
        }
        return existingExpense == nil ? "expenseeditor.addTitle" : "expenseeditor.editTitle"
    }

    private var amountSectionKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.amountSection" : "expenseeditor.actualSection"
    }

    private var paymentSectionKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.paymentSection" : "expenseeditor.paymentSection"
    }

    private var paymentHelpKey: LocalizedStringKey {
        if mode == .estimate { return "expenseestimate.paymentHelp" }
        return isPaid ? "expenseeditor.paymentPaidHelp" : "expenseeditor.paymentUnpaidHelp"
    }

    private var spentAtKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.spentAt" : "expenseeditor.spentAt"
    }

    private var transactionDetailsKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.transactionDetails" : "expenseeditor.transactionDetails"
    }

    private var transactionDetailsHelpKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.transactionDetailsHelp" : "expenseeditor.transactionDetailsHelp"
    }

    private var linkHelpKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.linkHelp" : "expenseeditor.linkHelp"
    }

    private var noteHelpKey: LocalizedStringKey {
        mode == .estimate ? "expenseestimate.noteHelp" : "expenseeditor.noteHelp"
    }

    private func save() {
        guard trip.currency != nil, let amountMinor = ExpenseMoney.amountMinor(from: amountText, currency: currency) else {
            validationMessage = String(localized: "expenseeditor.errorInvalid")
            return
        }
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPurchaseChannel = purchaseChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedConsumer = consumerUserID.flatMap { id in members.first { $0.userId == id } }
        // 已支出 → 实际支付时间；未支出 → 预计支付时间或留空（不设字段即 null）。
        let resolvedPaidAt: Date? = mode == .estimate
            ? (hasExpectedPaidAt ? paidAtDate : nil)
            : (isPaid ? paidAtDate : (hasExpectedPaidAt ? paidAtDate : nil))
        var clears: Set<String> = []
        if existingExpense != nil && normalizedNote.isEmpty { clears.insert("note") }
        if existingExpense != nil && normalizedPurchaseChannel.isEmpty { clears.insert("purchaseChannel") }
        if existingExpense != nil && paymentMethod.isEmpty { clears.insert("paymentMethod") }
        let hadSavedConsumer = existingExpense?.consumerUserID != nil
            || !(existingExpense?.consumerName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if hadSavedConsumer && consumerUserID == nil {
            clears.formUnion(["consumerUserId", "consumerName"])
        }
        if existingExpense?.paidAt != nil && resolvedPaidAt == nil { clears.insert("paidAt") }
        let request = ExpenseRequest(
            amountMinor: amountMinor,
            isEstimate: mode == .estimate,
            currency: currency,
            category: category,
            occurredOn: Self.dayFormatter.string(from: spentAt),
            spentAt: spentAt,
            paidAt: resolvedPaidAt,
            purchaseChannel: normalizedPurchaseChannel.isEmpty ? nil : normalizedPurchaseChannel,
            paymentMethod: paymentMethod.isEmpty ? nil : paymentMethod,
            consumerUserID: consumerUserID,
            consumerName: selectedConsumer?.visibleName,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            // 整组替换：空数组即为清空全部关联。
            cardIDs: cardIDs,
            fieldsToClear: clears
        )
        isSaving = true
        Task {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let body = try? encoder.encode(request)
            if body != lastSaveBody { saveKey = UUID(); lastSaveBody = body }
            let error = await onSave(request, saveKey)
            isSaving = false
            if let error { validationMessage = error } else { dismiss() }
        }
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return dayFormatter.date(from: value)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let recordedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

}

private struct ExpenseCardLinkPicker: View {
    let trip: SharedTripSnapshot
    let selectedCardIDs: [Int]
    let onToggle: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if matchingDays.isEmpty {
                    ContentUnavailableView(
                        LocalizedStringKey(searchText.isEmpty ? "expenseeditor.noLinkableCards" : "expenseeditor.noMatchingCards"),
                        systemImage: searchText.isEmpty ? "calendar.badge.exclamationmark" : "magnifyingglass",
                        description: Text(LocalizedStringKey(searchText.isEmpty ? "expenseeditor.noLinkableCardsHint" : "expenseeditor.noMatchingCardsHint"))
                    )
                } else {
                    List {
                        ForEach(matchingDays) { day in
                            Section(ExpenseCardLinkFormatter.day(day.date)) {
                                ForEach(matchingCards(in: day)) { card in
                                    cardRow(card)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("expenseeditor.chooseCardTitle")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "expenseeditor.searchCards")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }

    private var matchingDays: [TripDaySnapshot] {
        trip.days
            .sorted { ($0.date, $0.position) < ($1.date, $1.position) }
            .filter { !matchingCards(in: $0).isEmpty }
    }

    private func matchingCards(in day: TripDaySnapshot) -> [TravelCardSnapshot] {
        day.cards
            .filter { card in
                guard card.serverID != nil else { return false }
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                let searchable = [card.title, card.kind.title, card.place?.name, day.date]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return searchable.localizedCaseInsensitiveContains(query)
            }
            .sorted { ($0.startAt, $0.position) < ($1.startAt, $1.position) }
    }

    private func cardRow(_ card: TravelCardSnapshot) -> some View {
        let cardID = card.serverID!
        let isSelected = selectedCardIDs.contains(cardID)

        return Button {
            onToggle(cardID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: card.kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        PrimaryTabPalette.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(card.kind.title)
                        Text("·")
                        Text(ExpenseCardLinkFormatter.time(card.startAt))
                        if let place = card.place?.name, !place.isEmpty {
                            Text("·")
                            Text(place).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PrimaryTabPalette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? Text("common.selected") : Text(""))
    }
}

private enum ExpenseCardLinkFormatter {
    static func day(_ value: String) -> String {
        guard let date = input.date(from: value) else { return value }
        return date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated))
    }

    static func time(_ value: Date) -> String {
        value.formatted(date: .omitted, time: .shortened)
    }

    private static let input: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

}
