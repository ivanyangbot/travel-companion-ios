import MapKit
import SwiftData
import SwiftUI

/// “今日”页：全屏地图按时间顺序连线今日 POI，底部 swiper 横滑切换并点击查看详情。
struct TodayView: View {
    @ObservedObject var syncEngine: SyncEngine
    @Binding var section: JourneyView.Section
    @Environment(\.modelContext) private var modelContext
    @StateObject private var linkHandler = ExternalLinkHandler()
    @State private var selectedPOIIndex = 0
    @State private var cameraFocus: CLLocationCoordinate2D?
    @State private var cameraRequestID = 0
    @State private var detailCard: TravelCardSnapshot?
    @State private var hasCenteredOnPOIs = false
    /// 相对于排序后 days 的当前选中索引；nil 表示跟随“今日”基准。
    @State private var selectedDayIndex: Int?
    @State private var weatherEntries: [TodayWeatherEntry] = []

    var body: some View {
        Group {
            if let trip = syncEngine.trip, trip.isConfigured {
                let sorted = sortedDays(in: trip)
                if sorted.isEmpty {
                    ContentUnavailableView(
                        "还没有行程日期",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("在「旅程」中添加日期与卡片后，这里会显示今日地图。")
                    )
                } else {
                    let baseIndex = baseDayIndex(in: sorted)
                    let currentIndex = clampedDayIndex(sorted: sorted, baseIndex: baseIndex)
                    mapContent(days: sorted, currentIndex: currentIndex, baseIndex: baseIndex)
                }
            } else if case .failed(let message) = syncEngine.status {
                ContentUnavailableView("无法加载共享行程", systemImage: "wifi.exclamationmark", description: Text(message))
            } else {
                ProgressView("正在打开共享行程…")
            }
        }
        .sheet(item: $detailCard) { card in
            TodayCardDetailSheet(card: card, linkHandler: linkHandler)
        }
        .sheet(isPresented: Binding(
            get: { linkHandler.browserURL != nil },
            set: { if !$0 { linkHandler.browserURL = nil } }
        )) {
            if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
        }
        .alert("无法打开链接", isPresented: Binding(
            get: { linkHandler.alertMessage != nil },
            set: { if !$0 { linkHandler.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { linkHandler.alertMessage = nil }
        } message: {
            Text(linkHandler.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func mapContent(days: [TripDaySnapshot], currentIndex: Int, baseIndex: Int) -> some View {
        let day = days[currentIndex]
        let pois = poiCards(in: day)
        ZStack {
            if pois.isEmpty {
                ContentUnavailableView(
                    "这天还没有带地点的卡片",
                    systemImage: "mappin.slash",
                    description: Text("在「旅程」中为该日的卡片补上坐标后，这里会显示地图路径。")
                )
            } else {
                TodayMapCanvas(
                    points: mapPoints(pois: pois),
                    selectedIndex: clampedIndex(pois: pois),
                    cameraFocus: cameraFocus,
                    cameraRequestID: cameraRequestID
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        .black.opacity(0.74),
                        .black.opacity(0.42),
                        .black.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                mapHeader(for: day, currentIndex: currentIndex, baseIndex: baseIndex)
                Spacer()
            }
            .padding(.top, 2)
        }
        .task(id: "\(day.id)-\(poisKey(pois))") {
            hasCenteredOnPOIs = false
            fitAll(pois: pois)
            hasCenteredOnPOIs = true
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let horizontalDistance = value.translation.width
                    let verticalDistance = value.translation.height
                    guard abs(horizontalDistance) > abs(verticalDistance) * 1.25 else { return }

                    if horizontalDistance < -50 {
                        selectDay(days: days, index: currentIndex + 1)
                    } else if horizontalDistance > 50 {
                        selectDay(days: days, index: currentIndex - 1)
                    }
                }
        )
    }

    private func mapHeader(for day: TripDaySnapshot, currentIndex: Int, baseIndex: Int) -> some View {
        ZStack {
            Text(mapHeaderTitle(for: day, currentIndex: currentIndex, baseIndex: baseIndex))
                .font(.custom("PingFangTC-Semibold", size: 24))
                .tracking(0.024)
                .frame(height: 36)
                .foregroundStyle(.white)

            HStack {
                Spacer()
                Button {
                    withAnimation { section.toggle() }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.alternateTitle)
            }
        }
        .padding(.horizontal, 36)
        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
    }

    private func mapHeaderTitle(for day: TripDaySnapshot, currentIndex: Int, baseIndex: Int) -> String {
        let dateText: String
        if let date = Self.dayFormatter.date(from: day.date) {
            let components = Self.utcCalendar.dateComponents([.month, .day], from: date)
            if let month = components.month, let dayNumber = components.day {
                dateText = "\(chineseNumber(month))月\(chineseNumber(dayNumber))"
            } else {
                dateText = day.date
            }
        } else {
            dateText = day.date
        }
        return currentIndex == baseIndex ? "今日 \(dateText)" : dateText
    }

    private func chineseNumber(_ value: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        switch value {
        case 0...9:
            return digits[value]
        case 10:
            return "十"
        case 11...19:
            return "十\(digits[value % 10])"
        case 20...31:
            let tens = digits[value / 10]
            let ones = value % 10
            return ones == 0 ? "\(tens)十" : "\(tens)十\(digits[ones])"
        default:
            return String(value)
        }
    }

    @ViewBuilder
    private func daySwitcher(days: [TripDaySnapshot], currentIndex: Int, baseIndex: Int) -> some View {
        let day = days[currentIndex]
        let canPrevious = currentIndex > 0
        let canNext = currentIndex < days.count - 1
        let isToday = currentIndex == baseIndex
        HStack(spacing: 10) {
            Button {
                selectDay(days: days, index: currentIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .disabled(!canPrevious)
            .opacity(canPrevious ? 1 : 0.3)

            HStack(spacing: 6) {
                if isToday {
                    Text("今日")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.indigo))
                }
                Text(dayLabel(for: day) ?? day.date)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Button {
                selectDay(days: days, index: currentIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .disabled(!canNext)
            .opacity(canNext ? 1 : 0.3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -30 {
                        selectDay(days: days, index: currentIndex + 1)
                    } else if value.translation.width > 30 {
                        selectDay(days: days, index: currentIndex - 1)
                    }
                }
        )
    }

    private func selectDay(days: [TripDaySnapshot], index: Int) {
        guard days.indices.contains(index) else { return }
        hasCenteredOnPOIs = false
        selectedPOIIndex = 0
        weatherEntries = []
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedDayIndex = index
        }
    }

    /// 当日天气：当日所有位置都在 2.5 公里半径内时取地理中心查一次天气；
    /// 超过则按聚类中心查多地天气并同时展示。查询失败静默不显示。
    private func loadWeather(day: TripDaySnapshot, pois: [TravelCardSnapshot]) async {
        let points = pois.compactMap { card -> (coordinate: CLLocationCoordinate2D, name: String)? in
            guard let coordinate = coordinate(of: card) else { return nil }
            return (coordinate, card.place?.name ?? card.title)
        }
        guard !points.isEmpty else {
            weatherEntries = []
            return
        }
        let entries = await TodayWeatherProvider.shared.entries(for: points, date: day.date, today: Self.dayFormatter.string(from: Date()))
        guard !Task.isCancelled else { return }
        withAnimation { weatherEntries = entries }
    }

    @ViewBuilder
    private func poiSwiper(pois: [TravelCardSnapshot]) -> some View {
        let selection = Binding<Int>(
            get: { clampedIndex(pois: pois) },
            set: { selectedPOIIndex = $0 }
        )
        TabView(selection: selection) {
            ForEach(Array(pois.enumerated()), id: \.element.id) { index, card in
                POICard(
                    card: card,
                    index: index,
                    total: pois.count
                )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { detailCard = card }
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 140)
        .padding(.horizontal, 16)
    }

    private func sortedDays(in trip: SharedTripSnapshot) -> [TripDaySnapshot] {
        trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
    }

    /// “今日”基准：精确匹配今天，否则取最近的一天。
    private func baseDayIndex(in sorted: [TripDaySnapshot]) -> Int {
        let todayString = Self.dayFormatter.string(from: Date())
        if let exact = sorted.firstIndex(where: { $0.date == todayString }) { return exact }
        guard let today = Self.dayFormatter.date(from: todayString) else { return 0 }
        var bestIndex = 0
        var bestDelta = Double.infinity
        for (index, day) in sorted.enumerated() {
            guard let date = Self.dayFormatter.date(from: day.date) else { continue }
            let delta = abs(date.timeIntervalSince(today))
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func clampedDayIndex(sorted: [TripDaySnapshot], baseIndex: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = selectedDayIndex ?? baseIndex
        return min(max(0, index), sorted.count - 1)
    }

    /// 选中今日时标题为“今日”，切换到其他天则显示该日日期。
    private var currentNavigationTitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "今日" }
        let sorted = sortedDays(in: trip)
        guard !sorted.isEmpty else { return "今日" }
        let baseIndex = baseDayIndex(in: sorted)
        let currentIndex = clampedDayIndex(sorted: sorted, baseIndex: baseIndex)
        guard currentIndex != baseIndex else { return "今日" }
        return dayLabel(for: sorted[currentIndex]) ?? sorted[currentIndex].date
    }

    private func poiCards(in day: TripDaySnapshot) -> [TravelCardSnapshot] {
        day.cards
            .filter { $0.place?.latitude != nil && $0.place?.longitude != nil }
            .sorted { $0.startAt < $1.startAt }
    }

    private func coordinate(of card: TravelCardSnapshot) -> CLLocationCoordinate2D? {
        guard let place = card.place, let latitude = place.latitude, let longitude = place.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func mapPoints(pois: [TravelCardSnapshot]) -> [TodayMapPoint] {
        pois.compactMap { card in
            guard let coordinate = coordinate(of: card) else { return nil }
            return TodayMapPoint(
                id: card.id,
                title: card.place?.name ?? card.title,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    private func clampedIndex(pois: [TravelCardSnapshot]) -> Int {
        min(max(0, selectedPOIIndex), max(0, pois.count - 1))
    }

    private func poisKey(_ pois: [TravelCardSnapshot]) -> String {
        pois.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
    }

    private func dayLabel(for day: TripDaySnapshot) -> String? {
        guard let date = Self.dayFormatter.date(from: day.date) else { return day.date }
        return Self.displayFormatter.string(from: date)
    }

    private func fitAll(pois: [TravelCardSnapshot]) {
        guard !pois.isEmpty else { return }
        if pois.count == 1, let coordinate = coordinate(of: pois[0]) {
            cameraFocus = coordinate
        } else {
            cameraFocus = nil
        }
        cameraRequestID &+= 1
    }

    private func focus(pois: [TravelCardSnapshot], index: Int) {
        guard pois.indices.contains(index), let coordinate = coordinate(of: pois[index]) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraFocus = coordinate
            cameraRequestID &+= 1
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

private struct POICard: View {
    let card: TravelCardSnapshot
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: card.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.kind.title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    Text(card.title).font(.headline).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(index + 1) / \(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .glassEffect(.regular, in: Capsule())
            }
            if let place = card.place {
                Label(place.name, systemImage: "mappin")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Label(timeText, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("查看详情")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        if let endAt = card.endAt { return "\(formatter.string(from: card.startAt)) — \(formatter.string(from: endAt))" }
        return formatter.string(from: card.startAt)
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }
}

private struct TodayCardDetailSheet: View {
    let card: TravelCardSnapshot
    @ObservedObject var linkHandler: ExternalLinkHandler
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    timeRow
                    if let place = card.place { placeRow(place) }
                    if let code = card.bookingCode, !code.isEmpty { bookingRow(code) }
                    if let notes = card.notes, !notes.isEmpty {
                        Text(notes).font(.subheadline).foregroundStyle(.secondary)
                    }
                    actions
                }
                .padding()
            }
            .navigationTitle(card.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.kind.systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.kind.title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(card.title).font(.title3.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var timeRow: some View {
        Label(timeText, systemImage: "clock")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func placeRow(_ place: PlaceSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mappin").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.subheadline.weight(.medium))
                if let address = place.address, !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button("在地图打开", systemImage: "location") { linkHandler.openInMaps(for: place) }
                .buttonStyle(.glass)
                .disabled(place.latitude == nil || place.longitude == nil)
                .padding(8)
        }
    }

    private func bookingRow(_ code: String) -> some View {
        Text("订单号 \(code)")
            .font(.subheadline.monospaced())
            .padding(12)
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        if let value = card.url, let url = ExternalLinkHandler.validatedHTTPSURL(value) {
            HStack(spacing: 10) {
                Button("打开链接", systemImage: "arrow.up.right.square") { linkHandler.openPublicLink(value) }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                ShareLink(item: url, subject: Text(card.title), message: Text("来自同行的旅行卡片")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
            }
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月d日 HH:mm"
        if let endAt = card.endAt { return "\(formatter.string(from: card.startAt)) — \(formatter.string(from: endAt))" }
        return formatter.string(from: card.startAt)
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }
}
