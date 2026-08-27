import SwiftUI

struct DayEditor: View {
    let existingDay: TripDaySnapshot?
    let existingDates: Set<String>
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(existingDay: TripDaySnapshot? = nil, existingDates: Set<String>, onSave: @escaping (Date) -> Void) {
        self.existingDay = existingDay
        self.existingDates = existingDates
        self.onSave = onSave
        let initialDate = existingDay.flatMap { Self.formatter.date(from: $0.date) } ?? .now
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("dayeditor.dateLabel", selection: $date, displayedComponents: .date)
                if isDuplicate {
                    Text("dayeditor.duplicate")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(existingDay == nil ? "dayeditor.addTitle" : "dayeditor.editTitle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingDay == nil ? "dayeditor.addButton" : "common.save") {
                        onSave(date)
                        dismiss()
                    }
                    .disabled(isDuplicate)
                }
            }
        }
    }

    private var isDuplicate: Bool {
        let selected = Self.formatter.string(from: date)
        return existingDates.contains(selected) && selected != existingDay?.date
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
