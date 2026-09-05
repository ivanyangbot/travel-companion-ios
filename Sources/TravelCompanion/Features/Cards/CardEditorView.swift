import SwiftUI

struct CardEditorView: View {
    let day: TripDaySnapshot
    let existingCard: TravelCardSnapshot?
    let currency: String?
    let onSave: (CardRequest) -> Void
    let onImportLink: (String) async throws -> LinkImportResult

    @Environment(\.dismiss) private var dismiss
    @State private var kind: TravelCardSnapshot.Kind
    @State private var title: String
    @State private var startAt: Date
    @State private var hasEndAt: Bool
    @State private var endAt: Date
    @State private var bookingCode: String
    @State private var link: String
    @State private var coverImage: String?
    @State private var description: String
    @State private var fromAirport: String
    @State private var toAirport: String
    @State private var priceText: String
    @State private var actualPriceText: String
    @State private var ticketPriceText: String
    @State private var priceCurrency: String
    @State private var stayDurationText: String
    @State private var roomType: String
    @State private var hotelVisits: [HotelVisit]
    @State private var tips: [String]
    @State private var notes: String
    @State private var placeMode: PlaceMode
    @State private var placeName: String
    @State private var placeAddress: String
    @State private var selectedPlace: PlaceSearchResult?
    @State private var showsPlaceSearch = false
    @State private var validationMessage: String?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var didAutoImport = false

    init(day: TripDaySnapshot, existingCard: TravelCardSnapshot? = nil, currency: String? = nil, initialURL: String? = nil, onImportLink: @escaping (String) async throws -> LinkImportResult, onSave: @escaping (CardRequest) -> Void) {
        self.day = day
        self.existingCard = existingCard
        self.currency = currency
        self.onImportLink = onImportLink
        self.onSave = onSave
        _kind = State(initialValue: existingCard?.kind ?? .activity)
        _title = State(initialValue: existingCard?.title ?? "")
        _startAt = State(initialValue: existingCard?.startAt ?? Self.defaultStart(for: day))
        _hasEndAt = State(initialValue: existingCard?.endAt != nil)
        _endAt = State(initialValue: existingCard?.endAt ?? Self.defaultStart(for: day).addingTimeInterval(3600))
        _bookingCode = State(initialValue: existingCard?.bookingCode ?? "")
        _link = State(initialValue: existingCard?.url ?? initialURL ?? "")
        _coverImage = State(initialValue: existingCard?.images?.first)
        _description = State(initialValue: existingCard?.description ?? "")
        _fromAirport = State(initialValue: existingCard?.fromAirport ?? "")
        _toAirport = State(initialValue: existingCard?.toAirport ?? "")
        let priceCurrency = existingCard?.priceCurrency ?? currency ?? "CNY"
        _priceCurrency = State(initialValue: priceCurrency)
        _priceText = State(initialValue: Self.priceText(from: existingCard?.priceMinor, currency: priceCurrency))
        _actualPriceText = State(initialValue: Self.priceText(from: existingCard?.actualPriceMinor, currency: priceCurrency))
        _ticketPriceText = State(initialValue: Self.priceText(from: existingCard?.ticketPriceMinor, currency: priceCurrency))
        _stayDurationText = State(initialValue: existingCard?.stayDurationMinutes.map(String.init) ?? "")
        _roomType = State(initialValue: existingCard?.roomType ?? "")
        _hotelVisits = State(initialValue: existingCard?.hotelVisits ?? [])
        _tips = State(initialValue: existingCard?.tips ?? [])
        _notes = State(initialValue: existingCard?.notes ?? "")
        _placeMode = State(initialValue: (existingCard?.place?.id ?? 0) > 0 ? .existing : existingCard?.place == nil ? .none : .new)
        _placeName = State(initialValue: existingCard?.place?.name ?? "")
        _placeAddress = State(initialValue: existingCard?.place?.address ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("cardeditor.kindSection") {
                    Picker("cardeditor.kindLabel", selection: $kind) {
                        ForEach(TravelCardSnapshot.Kind.allCases) { kind in
                            Label(kind.title, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if let coverImage, CardImageURL.resolve(coverImage) != nil {
                    Section("cardeditor.coverSection") {
                        AsyncImage(url: CardImageURL.resolve(coverImage)) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                            case .success(let image):
                                image.resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 160)
                                    .clipped()
                            case .failure:
                                Label("cardeditor.coverFailed", systemImage: "photo.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if existingCard != nil {
                            Button("cardeditor.removeCover", role: .destructive) { self.coverImage = nil }
                        }
                    }
                }
                Section("cardeditor.basicSection") {
                    TextField(kind == .flight ? String(localized: "cardeditor.nameFlight") : kind == .hotel ? String(localized: "cardeditor.nameHotel") : String(localized: "cardeditor.nameActivity"), text: $title)
                    if kind == .hotel {
                        TextField("hotelcard.roomType", text: $roomType)
                    }
                    DatePicker("cardeditor.startTime", selection: $startAt)
                    Toggle("cardeditor.setEndTime", isOn: $hasEndAt)
                    if hasEndAt {
                        DatePicker("cardeditor.endTime", selection: $endAt, in: startAt...)
                    }
                    if kind == .flight {
                        TextField("cardeditor.fromAirport", text: $fromAirport)
                            .textInputAutocapitalization(.characters)
                        TextField("cardeditor.toAirport", text: $toAirport)
                            .textInputAutocapitalization(.characters)
                    }
                    Picker("expenseeditor.currencyLabel", selection: $priceCurrency) {
                        ForEach(Self.supportedCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                    TextField(String(format: String(localized: "cardeditor.estimatePlaceholder"), priceCurrency), text: $priceText)
                        .keyboardType(.decimalPad)
                    TextField("cardeditor.actualPlaceholder", text: $actualPriceText)
                        .keyboardType(.decimalPad)
                    if kind != .flight {
                        TextField("cardeditor.introPlaceholder", text: $description, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }
                if kind == .hotel && !hotelVisits.isEmpty {
                    Section("hotelcard.visits") {
                        ForEach(hotelVisits.indices, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text(hotelVisits[index].purpose == "checkIn" ? String(localized: "hotelcard.checkIn") : String(localized: "hotelcard.return"))
                                TextField("YYYY-MM-DD", text: $hotelVisits[index].date)
                                TextField("HH:mm", text: $hotelVisits[index].arrivalTime)
                                TextField("hotelcard.departureTime", text: Binding(
                                    get: { hotelVisits[index].departureTime ?? "" },
                                    set: { hotelVisits[index].departureTime = $0.isEmpty ? nil : $0 }
                                ))
                            }
                        }
                    }
                }
                Section("cardeditor.visitSection") {
                    TextField(String(format: String(localized: "cardeditor.ticketPlaceholder"), priceCurrency), text: $ticketPriceText)
                        .keyboardType(.decimalPad)
                    TextField("cardeditor.stayPlaceholder", text: $stayDurationText)
                        .keyboardType(.numberPad)
                    if !tips.isEmpty {
                        ForEach(tips.indices, id: \.self) { index in
                            HStack {
                                TextField(String(format: String(localized: "cardeditor.tipPlaceholder"), index + 1), text: $tips[index], axis: .vertical)
                                Button(role: .destructive) { tips.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text(String(format: String(localized: "cardeditor.deleteTipA11y"), index + 1)))
                            }
                        }
                    }
                    Button("cardeditor.addTip", systemImage: "plus") { tips.append("") }
                        .disabled(tips.count >= 10)
                }
                Section("cardeditor.placeSection") {
                    Picker("cardeditor.placeLabel", selection: $placeMode) {
                        Text("cardeditor.noPlace").tag(PlaceMode.none)
                        if existingCard?.place != nil { Text("cardeditor.keepPlace").tag(PlaceMode.existing) }
                        Text("cardeditor.newPlace").tag(PlaceMode.new)
                    }
                    if placeMode == .new {
                        if let selectedPlace {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedPlace.name).font(.subheadline.weight(.medium))
                                if let address = selectedPlace.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                                Label("cardeditor.savedCoords", systemImage: "location.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("cardeditor.changePlace", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                        } else {
                            Button("cardeditor.searchPlace", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                            Text("cardeditor.manualPlaceHint")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("cardeditor.placeName", text: $placeName)
                        TextField("cardeditor.addressPlaceholder", text: $placeAddress)
                    }
                }
                Section("cardeditor.bookingSection") {
                    TextField("cardeditor.orderPlaceholder", text: $bookingCode)
                        .textInputAutocapitalization(.characters)
                    TextField("cardeditor.linkPlaceholder", text: $link)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Text("cardeditor.linkHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if existingCard == nil, Self.xiaohongshuURL(link) != nil {
                        Button {
                            importFromCurrentLink()
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text(isImporting ? String(localized: "cardeditor.readingXhs") : String(localized: "cardeditor.aiXhsButton"))
                            }
                        }
                        .disabled(isImporting)
                    }
                }
                Section("cardeditor.notesSection") {
                    TextField("cardeditor.notesPlaceholder", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let importError {
                    Section {
                        Label(importError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                } else if let validationMessage {
                    Section { Text(validationMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existingCard == nil ? String(format: String(localized: "cardeditor.addTitle"), kind.title) : String(localized: "cardeditor.editTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("common.save", action: save) }
            }
            .sheet(isPresented: $showsPlaceSearch) {
                PlaceSearchView { result in
                    selectedPlace = result
                    placeName = result.name
                    placeAddress = result.address ?? ""
                }
            }
            .overlay {
                if isImporting {
                    ProgressView("cardeditor.readingXhs")
                        .padding(20)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .task {
                autoImportIfNeeded()
            }
        }
    }

    private func save() {
        guard kind != .hotel || HotelVisit.areValid(hotelVisits) else {
            validationMessage = String(localized: "hotelcard.invalidVisits")
            return
        }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            validationMessage = String(localized: "cardeditor.errorName")
            return
        }
        guard cleanedURL.isEmpty || ExternalLinkHandler.validatedHTTPSURL(cleanedURL) != nil else {
            // Keep all fields untouched so the user can correct only the invalid URL.
            validationMessage = String(localized: "cardeditor.errorLink")
            return
        }
        guard placeMode != .new || !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = String(localized: "cardeditor.errorPlace")
            return
        }
        let stayDuration = Self.stayDurationMinutes(from: stayDurationText)
        guard !Self.hasInvalidStayDuration(stayDurationText) else {
            validationMessage = String(localized: "cardeditor.errorStay")
            return
        }
        let cleanedTips = tips.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard cleanedTips.allSatisfy({ $0.count <= 500 }) else {
            validationMessage = String(localized: "cardeditor.errorTip")
            return
        }
        let isEditing = existingCard != nil
        var clearFields = Set<String>()
        if isEditing {
            if !hasEndAt { clearFields.insert("endAt") }
            if bookingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("bookingCode") }
            if cleanedURL.isEmpty { clearFields.insert("url") }
            if coverImage == nil { clearFields.insert("images") }
            if kind == .flight || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearFields.insert("description")
            }
            if fromAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("fromAirport") }
            if toAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("toAirport") }
            if CardPrice.minorUnits(from: priceText, currency: priceCurrency) == nil { clearFields.insert("priceMinor") }
            if CardPrice.minorUnits(from: actualPriceText, currency: priceCurrency) == nil { clearFields.insert("actualPriceMinor") }
            if CardPrice.minorUnits(from: ticketPriceText, currency: priceCurrency) == nil { clearFields.insert("ticketPriceMinor") }
            if stayDuration == nil { clearFields.insert("stayDurationMinutes") }
            if kind != .hotel || roomType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearFields.insert("roomType")
            }
            if cleanedTips.isEmpty { clearFields.insert("tips") }
            if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("notes") }
            if placeMode == .none { clearFields.insert("place") }
        }
        let formatter = ISO8601DateFormatter()
        // Preserve the full images array when editing; the editor only edits the
        // first (cover), so keep any remaining swiper images intact.
        let imagesValue: [String]? = {
            if let coverImage {
                if let rest = existingCard?.images?.dropFirst(), !rest.isEmpty {
                    return [coverImage] + Array(rest)
                }
                return [coverImage]
            }
            return nil
        }()
        let request = CardRequest(
            dayId: day.serverID,
            kind: kind,
            title: cleanedTitle,
            startAt: formatter.string(from: startAt),
            endAt: hasEndAt ? formatter.string(from: endAt) : nil,
            place: placeMode == .new ? selectedPlace?.request ?? PlaceRequest(name: placeName.trimmingCharacters(in: .whitespacesAndNewlines), address: emptyToNil(placeAddress), latitude: nil, longitude: nil, placeId: nil, cityCode: nil) : nil,
            placeId: placeMode == .existing ? existingCard?.place.flatMap { $0.id > 0 ? $0.id : nil } : nil,
            bookingCode: emptyToNil(bookingCode),
            url: cleanedURL.isEmpty ? nil : cleanedURL,
            description: kind == .flight ? nil : emptyToNil(description),
            fromAirport: emptyToNil(fromAirport),
            toAirport: emptyToNil(toAirport),
            priceMinor: CardPrice.minorUnits(from: priceText, currency: priceCurrency),
            actualPriceMinor: CardPrice.minorUnits(from: actualPriceText, currency: priceCurrency),
            ticketPriceMinor: CardPrice.minorUnits(from: ticketPriceText, currency: priceCurrency),
            priceCurrency: priceCurrency,
            stayDurationMinutes: stayDuration,
            roomType: kind == .hotel ? emptyToNil(roomType) : nil,
            hotelVisits: kind == .hotel ? hotelVisits : [],
            tips: cleanedTips.isEmpty ? nil : cleanedTips,
            images: imagesValue,
            notes: emptyToNil(notes),
            position: existingCard?.position ?? day.cards.count,
            fieldsToClear: clearFields
        )
        onSave(request)
        dismiss()
    }

    private func importFromCurrentLink() {
        guard let url = Self.xiaohongshuURL(link) else { return }
        importFrom(link: url)
    }

    private func autoImportIfNeeded() {
        guard !didAutoImport, existingCard == nil, let url = Self.xiaohongshuURL(link) else { return }
        didAutoImport = true
        importFrom(link: url)
    }

    private func importFrom(link url: String) {
        isImporting = true
        importError = nil
        Task {
            do {
                let result = try await onImportLink(url)
                kind = result.kind
                title = result.title
                if let place = result.place, !place.isEmpty {
                    placeName = place
                    placeAddress = ""
                    selectedPlace = nil
                    placeMode = .new
                }
                notes = result.notes ?? notes
                link = result.url
                coverImage = result.imageURL
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }

    private static func xiaohongshuURL(_ value: String) -> String? {
        guard let url = ExternalLinkHandler.validatedHTTPSURL(value) else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "xhslink.com" || host.hasSuffix(".xhslink.com") || host.hasSuffix("xiaohongshu.com") {
            return url.absoluteString
        }
        return nil
    }

    private static func stayDurationMinutes(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), (1 ... 100_000).contains(value) else { return nil }
        return value
    }

    /// Non-empty input that fails to parse must block the save instead of
    /// silently dropping the value the user typed.
    private static func hasInvalidStayDuration(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && stayDurationMinutes(from: trimmed) == nil
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func priceText(from minor: Int64?, currency: String?) -> String {
        guard let minor else { return "" }
        let exponent = CardPrice.minorExponent(for: currency)
        let divisor = pow(10.0, Double(exponent))
        let value = Double(minor) / divisor
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    private static let supportedCurrencies = [
        "CNY", "HKD", "IDR", "USD", "EUR", "GBP", "JPY", "SGD", "MYR", "THB", "KRW", "AUD", "CAD", "TWD", "VND",
    ]

    private static func defaultStart(for day: TripDaySnapshot) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day.date) ?? .now
    }

    private enum PlaceMode: String, Hashable {
        case none, existing, new
    }
}
