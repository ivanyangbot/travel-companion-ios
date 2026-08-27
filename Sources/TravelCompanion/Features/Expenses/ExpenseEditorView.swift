import SwiftUI

struct ExpenseEditorView: View {
    let trip: SharedTripSnapshot
    let existingExpense: ExpenseSnapshot?
    let onSave: (ExpenseRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var category: ExpenseCategory
    @State private var occurredOn: Date
    @State private var note: String
    @State private var cardID: Int?
    @State private var validationMessage: String?

    init(trip: SharedTripSnapshot, existingExpense: ExpenseSnapshot? = nil, initialDate: Date? = nil, onSave: @escaping (ExpenseRequest) -> Void) {
        self.trip = trip
        self.existingExpense = existingExpense
        self.onSave = onSave
        let currency = trip.currency ?? "CNY"
        _amountText = State(initialValue: existingExpense.map { ExpenseMoney.inputString($0.amountMinor, currency: currency) } ?? "")
        _category = State(initialValue: existingExpense?.category ?? .other)
        _occurredOn = State(initialValue: Self.date(from: existingExpense?.occurredOn) ?? initialDate ?? .now)
        _note = State(initialValue: existingExpense?.note ?? "")
        _cardID = State(initialValue: existingExpense?.cardID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("expenseeditor.actualSection") {
                    TextField("expenseeditor.amountPlaceholder", text: $amountText)
                        .keyboardType(.decimalPad)
                    Text(String(format: String(localized: "expenseeditor.currencyNote"), trip.currency ?? String(localized: "expenseeditor.currencyPending")))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("expenseeditor.categorySection") {
                    Picker("expenseeditor.categoryLabel", selection: $category) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                    DatePicker("expenseeditor.dateLabel", selection: $occurredOn, displayedComponents: .date)
                }
                Section("expenseeditor.linkSection") {
                    Picker("expenseeditor.cardLabel", selection: $cardID) {
                        Text("expenseeditor.noCard").tag(Int?.none)
                        ForEach(allCards, id: \.serverID) { card in
                            Text(card.title).tag(Optional(card.serverID!))
                        }
                    }
                }
                Section("expenseeditor.noteSection") {
                    TextField("expenseeditor.notePlaceholder", text: $note, axis: .vertical)
                        .lineLimit(2...5)
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
        }
    }

    private var allCards: [TravelCardSnapshot] {
        trip.days.flatMap(\.cards).filter { $0.serverID != nil }.sorted { $0.title < $1.title }
    }

    private func save() {
        guard let currency = trip.currency, let amountMinor = ExpenseMoney.amountMinor(from: amountText, currency: currency) else {
            validationMessage = String(localized: "expenseeditor.errorInvalid")
            return
        }
        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var clears: Set<String> = []
        if existingExpense != nil && normalizedNote.isEmpty { clears.insert("note") }
        if existingExpense?.cardID != nil && cardID == nil { clears.insert("cardId") }
        onSave(ExpenseRequest(amountMinor: amountMinor, currency: currency, category: category, occurredOn: Self.dayFormatter.string(from: occurredOn), note: normalizedNote.isEmpty ? nil : normalizedNote, cardID: cardID, fieldsToClear: clears))
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
}
