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
                Section("实际价") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                    Text("币种：\(trip.currency ?? "请先设置")；金额会精确保存为最小货币单位。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("归类") {
                    Picker("类别", selection: $category) {
                        ForEach(ExpenseCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                    DatePicker("发生日期", selection: $occurredOn, displayedComponents: .date)
                }
                Section("关联行程（可选）") {
                    Picker("行程卡片", selection: $cardID) {
                        Text("不关联").tag(Int?.none)
                        ForEach(allCards, id: \.serverID) { card in
                            Text(card.title).tag(Optional(card.serverID!))
                        }
                    }
                }
                Section("备注（可选）") {
                    TextField("例如：机场到酒店", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let validationMessage { Text(validationMessage).foregroundStyle(.red) }
            }
            .navigationTitle(existingExpense == nil ? "新增实际价" : "编辑实际价")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
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
            validationMessage = "请输入有效的正数金额，且小数位不能超过该币种精度。"
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
