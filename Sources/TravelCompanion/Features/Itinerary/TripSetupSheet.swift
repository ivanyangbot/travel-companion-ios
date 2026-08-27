import SwiftUI

struct TripSetupSheet: View {
    let initialTrip: SharedTripSnapshot?
    let isNewTrip: Bool
    let onSave: (String, Date, Date, String) -> Void

    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var currency: String

    init(initialTrip: SharedTripSnapshot? = nil, isNewTrip: Bool = false, onSave: @escaping (String, Date, Date, String) -> Void) {
        self.initialTrip = initialTrip
        self.isNewTrip = isNewTrip
        self.onSave = onSave
        let today = Date()
        _destination = State(initialValue: initialTrip?.destination ?? "")
        _startDate = State(initialValue: initialTrip?.startDate.flatMap(Self.formatter.date(from:)) ?? today)
        _endDate = State(initialValue: initialTrip?.endDate.flatMap(Self.formatter.date(from:)) ?? Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today)
        _currency = State(initialValue: initialTrip?.currency ?? "CNY")
    }

    init(initialTrip summary: TripSummary, onSave: @escaping (String, Date, Date, String) -> Void) {
        let snapshot = SharedTripSnapshot(
            id: summary.id,
            destination: summary.destination,
            startDate: summary.startDate,
            endDate: summary.endDate,
            currency: summary.currency,
            version: summary.version,
            updatedAt: summary.updatedAt,
            days: []
        )
        initialTrip = snapshot
        isNewTrip = false
        self.onSave = onSave
        let today = Date()
        _destination = State(initialValue: summary.destination ?? "")
        _startDate = State(initialValue: summary.startDate.flatMap(Self.formatter.date(from:)) ?? today)
        _endDate = State(initialValue: summary.endDate.flatMap(Self.formatter.date(from:)) ?? Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today)
        _currency = State(initialValue: summary.currency ?? "CNY")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNewTrip ? "tripsetup.createTitle" : (initialTrip == nil ? "tripsetup.planTitle" : "tripsetup.editTitle"))
                .font(.title2.bold())
            Text(isNewTrip ? "tripsetup.createDesc" : "tripsetup.editDesc")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("tripsetup.destinationPlaceholder", text: $destination)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.roundedBorder)
            DatePicker("tripsetup.departure", selection: $startDate, displayedComponents: .date)
            DatePicker("tripsetup.return", selection: $endDate, in: startDate..., displayedComponents: .date)
            TextField("tripsetup.currencyPlaceholder", text: $currency)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button(isNewTrip ? "tripsetup.createButton" : "tripsetup.saveButton") {
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
