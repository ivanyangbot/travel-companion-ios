import SwiftUI

struct TripSetupSheet: View {
    let initialTrip: SharedTripSnapshot?
    let onSave: (String, Date, Date, String) -> Void

    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var currency: String

    init(initialTrip: SharedTripSnapshot? = nil, onSave: @escaping (String, Date, Date, String) -> Void) {
        self.initialTrip = initialTrip
        self.onSave = onSave
        let today = Date()
        _destination = State(initialValue: initialTrip?.destination ?? "")
        _startDate = State(initialValue: initialTrip?.startDate.flatMap(Self.formatter.date(from:)) ?? today)
        _endDate = State(initialValue: initialTrip?.endDate.flatMap(Self.formatter.date(from:)) ?? Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today)
        _currency = State(initialValue: initialTrip?.currency ?? "CNY")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(initialTrip == nil ? "从这里开始规划" : "编辑共享行程")
                .font(.title2.bold())
            Text("这就是你们唯一的共享行程。任何拥有 API 地址的人都可以查看和修改它，请勿填写敏感信息。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("目的地，例如：东京", text: $destination)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.roundedBorder)
            DatePicker("出发", selection: $startDate, displayedComponents: .date)
            DatePicker("返程", selection: $endDate, in: startDate..., displayedComponents: .date)
            TextField("货币（ISO 代码）", text: $currency)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("保存共享行程") {
                onSave(destination, startDate, endDate, currency)
            }
            .buttonStyle(.borderedProminent)
            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currency.count != 3)
        }
        .padding()
        .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
