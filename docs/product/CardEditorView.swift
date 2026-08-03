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
    @State private var stayDurationText: String
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
        _priceText = State(initialValue: Self.priceText(from: existingCard?.priceMinor, currency: currency))
        _actualPriceText = State(initialValue: Self.priceText(from: existingCard?.actualPriceMinor, currency: currency))
        _ticketPriceText = State(initialValue: Self.priceText(from: existingCard?.ticketPriceMinor, currency: currency))
        _stayDurationText = State(initialValue: existingCard?.stayDurationMinutes.map(String.init) ?? "")
        _tips = State(initialValue: existingCard?.tips ?? [])
        _notes = State(initialValue: existingCard?.notes ?? "")
        _placeMode = State(initialValue: (existingCard?.place?.id ?? 0) > 0 ? .existing : existingCard?.place == nil ? .none : .new)
        _placeName = State(initialValue: existingCard?.place?.name ?? "")
        _placeAddress = State(initialValue: existingCard?.place?.address ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("卡片类型", selection: $kind) {
                        ForEach(TravelCardSnapshot.Kind.allCases) { kind in
                            Label(kind.title, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if let coverImage, CardImageURL.resolve(coverImage) != nil {
                    Section("封面图") {
                        AsyncImage(url: CardImageURL.resolve(coverImage)) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                            case .success(let image):
                                image.resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 160)
                                    .clipped()
                            case .failure:
                                Label("封面图加载失败", systemImage: "photo.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if existingCard != nil {
                            Button("移除封面图", role: .destructive) { self.coverImage = nil }
                        }
                    }
                }
                Section("基本信息") {
                    TextField(kind == .flight ? "航班或路线名称" : kind == .hotel ? "酒店名称" : "活动名称", text: $title)
                    DatePicker("开始时间", selection: $startAt)
                    Toggle("设置结束时间", isOn: $hasEndAt)
                    if hasEndAt {
                        DatePicker("结束时间", selection: $endAt, in: startAt...)
                    }
                    if kind == .flight {
                        TextField("出发机场（如 HND）", text: $fromAirport)
                            .textInputAutocapitalization(.characters)
                        TextField("到达机场（如 KIX）", text: $toAirport)
                            .textInputAutocapitalization(.characters)
                    }
                    TextField("预估价（\(currency ?? "本币")）", text: $priceText)
                        .keyboardType(.decimalPad)
                    TextField("实际价（可选，填写后只显示实际价）", text: $actualPriceText)
                        .keyboardType(.decimalPad)
                    TextField("介绍（可选）", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("参观信息") {
                    TextField("门票价格（\(currency ?? "本币")，可选）", text: $ticketPriceText)
                        .keyboardType(.decimalPad)
                    TextField("停留时长（分钟，可选）", text: $stayDurationText)
                        .keyboardType(.numberPad)
                    if !tips.isEmpty {
                        ForEach(tips.indices, id: \.self) { index in
                            HStack {
                                TextField("Tip \(index + 1)", text: $tips[index], axis: .vertical)
                                Button(role: .destructive) { tips.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除 Tip \(index + 1)")
                            }
                        }
                    }
                    Button("添加 Tip", systemImage: "plus") { tips.append("") }
                        .disabled(tips.count >= 10)
                }
                Section("地点") {
                    Picker("地点", selection: $placeMode) {
                        Text("不添加地点").tag(PlaceMode.none)
                        if existingCard?.place != nil { Text("保留现有地点").tag(PlaceMode.existing) }
                        Text("填写新地点").tag(PlaceMode.new)
                    }
                    if placeMode == .new {
                        if let selectedPlace {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedPlace.name).font(.subheadline.weight(.medium))
                                if let address = selectedPlace.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                                Label("已保存地图坐标", systemImage: "location.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("更换搜索地点", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                        } else {
                            Button("搜索地点并保存坐标", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                            Text("或者手动填写地点（手动地点无法估算路线）。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("地点名称", text: $placeName)
                        TextField("地址（可选）", text: $placeAddress)
                    }
                }
                Section("预订与联动") {
                    TextField("订单号（可选）", text: $bookingCode)
                        .textInputAutocapitalization(.characters)
                    TextField("HTTPS 公开链接（可选）", text: $link)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Text("可粘贴飞猪、小红书等公开网页链接；App 不读取这些平台的私有数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if existingCard == nil, Self.xiaohongshuURL(link) != nil {
                        Button {
                            importFromCurrentLink()
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                Text(isImporting ? "正在读取小红书…" : "AI 读取小红书生成卡片")
                            }
                        }
                        .disabled(isImporting)
                    }
                }
                Section("备注") {
                    TextField("备注（可选）", text: $notes, axis: .vertical)
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
            .navigationTitle(existingCard == nil ? "添加\(kind.title)卡片" : "编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
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
                    ProgressView("正在读取小红书…")
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
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            validationMessage = "请填写卡片名称。"
            return
        }
        guard cleanedURL.isEmpty || ExternalLinkHandler.validatedHTTPSURL(cleanedURL) != nil else {
            // Keep all fields untouched so the user can correct only the invalid URL.
            validationMessage = "链接必须是有效的 HTTPS 地址。"
            return
        }
        guard placeMode != .new || !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "请填写地点名称，或选择不添加地点。"
            return
        }
        let stayDuration = Self.stayDurationMinutes(from: stayDurationText)
        guard !Self.hasInvalidStayDuration(stayDurationText) else {
            validationMessage = "停留时长请填写 1–100000 的正整数分钟。"
            return
        }
        let cleanedTips = tips.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard cleanedTips.allSatisfy({ $0.count <= 500 }) else {
            validationMessage = "每条 Tip 最多 500 个字符。"
            return
        }
        let isEditing = existingCard != nil
        var clearFields = Set<String>()
        if isEditing {
            if !hasEndAt { clearFields.insert("endAt") }
            if bookingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("bookingCode") }
            if cleanedURL.isEmpty { clearFields.insert("url") }
            if coverImage == nil { clearFields.insert("images") }
            if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("description") }
            if fromAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("fromAirport") }
            if toAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearFields.insert("toAirport") }
            if CardPrice.minorUnits(from: priceText, currency: currency) == nil { clearFields.insert("priceMinor") }
            if CardPrice.minorUnits(from: actualPriceText, currency: currency) == nil { clearFields.insert("actualPriceMinor") }
            if CardPrice.minorUnits(from: ticketPriceText, currency: currency) == nil { clearFields.insert("ticketPriceMinor") }
            if stayDuration == nil { clearFields.insert("stayDurationMinutes") }
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
            description: emptyToNil(description),
            fromAirport: emptyToNil(fromAirport),
            toAirport: emptyToNil(toAirport),
            priceMinor: CardPrice.minorUnits(from: priceText, currency: currency),
            actualPriceMinor: CardPrice.minorUnits(from: actualPriceText, currency: currency),
            ticketPriceMinor: CardPrice.minorUnits(from: ticketPriceText, currency: currency),
            stayDurationMinutes: stayDuration,
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
