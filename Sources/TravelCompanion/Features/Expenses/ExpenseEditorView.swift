import SwiftUI

struct ExpenseEditorView: View {
    let trip: SharedTripSnapshot
    let existingExpense: ExpenseSnapshot?
    let members: [TripMemberSummary]
    let onSave: (ExpenseRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var currency: String
    @State private var category: ExpenseCategory
    @State private var spentAt: Date
    @State private var purchaseChannel: String
    @State private var paymentMethod: String
    @State private var consumerUserID: Int?
    @State private var note: String
    @State private var cardID: Int?
    @State private var showsCardPicker = false
    @State private var validationMessage: String?

    init(trip: SharedTripSnapshot, existingExpense: ExpenseSnapshot? = nil, members: [TripMemberSummary] = [], initialDate: Date? = nil, onSave: @escaping (ExpenseRequest) -> Void) {
        self.trip = trip
        self.existingExpense = existingExpense
        self.members = members
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
        _cardID = State(initialValue: existingExpense?.cardID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("expenseeditor.actualSection") {
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
                    DatePicker(
                        "expenseeditor.spentAt",
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
                    Text("expenseeditor.transactionDetails")
                } footer: {
                    Text("expenseeditor.transactionDetailsHelp")
                }
                Section {
                    Button {
                        showsCardPicker = true
                    } label: {
                        linkedCardSelectionRow
                    }
                    .buttonStyle(.plain)

                    if cardID != nil {
                        Button("expenseeditor.unlinkCard", systemImage: "link.badge.minus", role: .destructive) {
                            cardID = nil
                        }
                    }
                } header: {
                    Text("expenseeditor.linkSection")
                } footer: {
                    Text("expenseeditor.linkHelp")
                }
                Section {
                    TextField("expenseeditor.notePlaceholder", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("expenseeditor.noteSection")
                } footer: {
                    Text("expenseeditor.noteHelp")
                }
                if let validationMessage { Text(validationMessage).foregroundStyle(.red) }
            }
            .navigationTitle(existingExpense == nil ? "expenseeditor.addTitle" : "expenseeditor.editTitle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }
                        .disabled(trip.currency == nil)
                }
            }
            .sheet(isPresented: $showsCardPicker) {
                ExpenseCardLinkPicker(
                    trip: trip,
                    selectedCardID: cardID,
                    unavailableCardIDs: unavailableCardIDs
                ) { selectedID in
                    cardID = selectedID
                    showsCardPicker = false
                }
            }
        }
    }

    private var allCards: [TravelCardSnapshot] {
        trip.days.flatMap(\.cards).filter { $0.serverID != nil }.sorted { $0.title < $1.title }
    }

    private var linkedCard: TravelCardSnapshot? {
        guard let cardID else { return nil }
        return allCards.first { $0.serverID == cardID }
    }

    private var unavailableCardIDs: Set<Int> {
        Set(
            trip.expenses
                .filter { $0.id != existingExpense?.id }
                .compactMap(\.cardID)
        )
    }

    @ViewBuilder
    private var linkedCardSelectionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: linkedCard?.kind.systemImage ?? "link")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(linkedCard == nil ? PrimaryTabPalette.secondaryText : PrimaryTabPalette.accent)
                .frame(width: 38, height: 38)
                .background(
                    (linkedCard == nil ? Color.secondary : PrimaryTabPalette.accent).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(linkedCard?.title ?? String(localized: "expenseeditor.chooseCard"))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let linkedCard {
                    Text(linkedCard.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("expenseeditor.chooseCardHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func save() {
        guard trip.currency != nil, let amountMinor = ExpenseMoney.amountMinor(from: amountText, currency: currency) else {
            validationMessage = String(localized: "expenseeditor.errorInvalid")
            return
        }
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPurchaseChannel = purchaseChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedConsumer = consumerUserID.flatMap { id in members.first { $0.userId == id } }
        var clears: Set<String> = []
        if existingExpense != nil && normalizedNote.isEmpty { clears.insert("note") }
        if existingExpense != nil && normalizedPurchaseChannel.isEmpty { clears.insert("purchaseChannel") }
        if existingExpense != nil && paymentMethod.isEmpty { clears.insert("paymentMethod") }
        if existingExpense?.consumerUserID != nil && consumerUserID == nil {
            clears.formUnion(["consumerUserId", "consumerName"])
        }
        if existingExpense?.cardID != nil && cardID == nil { clears.insert("cardId") }
        onSave(ExpenseRequest(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            occurredOn: Self.dayFormatter.string(from: spentAt),
            spentAt: spentAt,
            purchaseChannel: normalizedPurchaseChannel.isEmpty ? nil : normalizedPurchaseChannel,
            paymentMethod: paymentMethod.isEmpty ? nil : paymentMethod,
            consumerUserID: consumerUserID,
            consumerName: selectedConsumer?.visibleName ?? existingExpense?.consumerName,
            note: normalizedNote.isEmpty ? nil : normalizedNote,
            cardID: cardID,
            fieldsToClear: clears
        ))
        dismiss()
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
    let selectedCardID: Int?
    let unavailableCardIDs: Set<Int>
    let onSelect: (Int?) -> Void

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
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                if selectedCardID != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("expenseeditor.noCard") { onSelect(nil) }
                    }
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
        let isSelected = cardID == selectedCardID
        let isUnavailable = unavailableCardIDs.contains(cardID)

        return Button {
            guard !isUnavailable else { return }
            onSelect(cardID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: card.kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isUnavailable ? Color.secondary : PrimaryTabPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        (isUnavailable ? Color.secondary : PrimaryTabPalette.accent).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .foregroundStyle(isUnavailable ? .secondary : .primary)
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
                } else if isUnavailable {
                    Text("expenseeditor.alreadyLinked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .accessibilityValue(
            isSelected
                ? Text("common.selected")
                : isUnavailable ? Text("expenseeditor.alreadyLinked") : Text("")
        )
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
