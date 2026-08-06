import MapKit
import SwiftData
import SwiftUI
import UIKit

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
    @State private var showsSharingSheet = false
    @State private var showsTripPicker = false
    @State private var activeQuickAction: TodayQuickAction?
    @State private var isQuickActionsExpanded = false
    @State private var isReloading = false
    @State private var isRouteLoading = false
    @State private var routeRefreshID = 0
    @State private var expandedPOICardID: UUID?
    @State private var poiSwipeStartIndex: Int?
    @State private var isMapViewportMoving = false
    @State private var hasVisiblePOIInMap = true
    @State private var isTimelineSwitching = false
    @StateObject private var userLocationProvider = TodayUserLocationProvider()

    var body: some View {
        Group {
            if let trip = syncEngine.trip {
                if trip.isConfigured {
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
                } else {
                    journeySetupPrompt(
                        title: "先完成行程设置",
                        description: "填写目的地、日期和币种后，这里会显示今日地图。"
                    )
                }
            } else if case .failed(let message) = syncEngine.status {
                ContentUnavailableView("无法加载共享行程", systemImage: "wifi.exclamationmark", description: Text(message))
            } else if case .synced = syncEngine.status {
                journeySetupPrompt(
                    title: "还没有旅程",
                    description: "创建第一段旅程后，就可以开始安排行程和查看今日地图。"
                )
            } else if case .localOnly = syncEngine.status {
                journeySetupPrompt(
                    title: "还没有旅程",
                    description: "前往旅程页创建第一段本地旅程，即可开始规划。"
                )
            } else {
                ProgressView("正在打开共享行程…")
            }
        }
        .onAppear {
            userLocationProvider.start()
        }
        .sheet(item: $detailCard) { card in
            TodayCardDetailSheet(card: card, linkHandler: linkHandler)
        }
        .sheet(isPresented: Binding(
            get: { showsSharingSheet },
            set: {
                showsSharingSheet = $0
                if !$0 { clearQuickAction(.addCompanion) }
            }
        )) {
            TripSharingSheet(syncEngine: syncEngine)
        }
        .confirmationDialog("选择行程", isPresented: Binding(
            get: { showsTripPicker },
            set: {
                showsTripPicker = $0
                if !$0 { clearQuickAction(.tripSelection) }
            }
        ), titleVisibility: .visible) {
            ForEach(syncEngine.trips) { summary in
                Button {
                    guard summary.id != syncEngine.selectedTripID else { return }
                    selectedDayIndex = nil
                    selectedPOIIndex = 0
                    cameraFocus = nil
                    weatherEntries = []
                    Task { await syncEngine.selectTrip(summary.id) }
                } label: {
                    if summary.id == syncEngine.selectedTripID {
                        Label(summary.displayName, systemImage: "checkmark")
                    } else {
                        Text(summary.displayName)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择要在首页显示的旅行行程。")
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

    private func journeySetupPrompt(title: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "map")
        } description: {
            Text(description)
        } actions: {
            Button("前往旅程") {
                withAnimation { section = .itinerary }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func mapContent(days: [TripDaySnapshot], currentIndex: Int, baseIndex: Int) -> some View {
        let day = days[currentIndex]
        let pois = poiCards(in: day)
        let showsPOIOverlay = !pois.isEmpty
            && !isQuickActionsExpanded
            && (!isMapViewportMoving || isTimelineSwitching)
            && hasVisiblePOIInMap
        let focusBottomInset = poiFocusBottomInset(for: pois, showsPOIOverlay: showsPOIOverlay)
        ZStack {
            MapLibreTodayMapCanvas(
                points: mapPoints(pois: pois),
                // A selected map marker is the visual counterpart of the
                // visible POI card. When the action drawer covers that card,
                // keep every marker compact and neutral instead.
                selectedIndex: isQuickActionsExpanded ? nil : clampedIndex(pois: pois),
                cameraFocus: cameraFocus,
                cameraRequestID: cameraRequestID,
                focusTopInset: 94,
                focusBottomInset: focusBottomInset,
                overviewBottomInset: isQuickActionsExpanded ? 112 : 240,
                routeRefreshID: routeRefreshID
            ) { isLoading in
                // UIViewRepresentable 更新期间不能同步写入 SwiftUI 状态。
                DispatchQueue.main.async {
                    updateRouteLoading(isLoading)
                }
            } onViewportStateChanged: { isMoving, hasVisiblePOI in
                // MapLibre's delegate runs during UIKit layout and gestures;
                // defer the SwiftUI state write to the next run-loop turn.
                DispatchQueue.main.async {
                    updatePOIOverlayVisibility(
                        isMapMoving: isMoving,
                        hasVisiblePOI: hasVisiblePOI
                    )
                }
            }
            .ignoresSafeArea()

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
                mapHeader(
                    days: days,
                    for: day,
                    pois: pois,
                    currentIndex: currentIndex,
                    baseIndex: baseIndex
                )
                Spacer()
                if showsPOIOverlay {
                    let timelineWidth = min(390, max(0, UIScreen.main.bounds.width - 40))
                    VStack(spacing: 8) {
                        TodayDateTimeline(
                            days: days,
                            selectedIndex: currentIndex,
                            todayIndex: baseIndex,
                            width: timelineWidth,
                            label: { day, isToday in
                                timelineLabel(for: day, isToday: isToday)
                            }
                        ) { index in
                            selectDay(days: days, index: index, keepsPOIOverlayVisible: true)
                        }

                        poiSwiper(
                            pois: pois,
                            days: days,
                            currentDayIndex: currentIndex,
                            userLocation: userLocationProvider.coordinate
                        )
                    }
                    .padding(.bottom, 112)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
        }
        .task(id: "\(day.id)-\(poisKey(pois))") {
            hasCenteredOnPOIs = false
            fitAll(pois: pois)
            hasCenteredOnPOIs = true
        }
    }

    private func daySwipeGesture(days: [TripDaySnapshot], currentIndex: Int) -> some Gesture {
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
    }

    private func mapHeader(
        days: [TripDaySnapshot],
        for day: TripDaySnapshot,
        pois: [TravelCardSnapshot],
        currentIndex: Int,
        baseIndex: Int
    ) -> some View {
        ZStack(alignment: .top) {
            Text(mapHeaderTitle(for: day, currentIndex: currentIndex, baseIndex: baseIndex))
                .font(.custom("PingFangTC-Semibold", size: 24))
                .tracking(0.024)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .simultaneousGesture(daySwipeGesture(days: days, currentIndex: currentIndex))

            HStack {
                Spacer()
                VStack(spacing: 16) {
                    Button {
                        withAnimation(.snappy(duration: 0.28)) { section = .itinerary }
                    } label: {
                        Image("icon-timeview-outline")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 48, height: 48)
                    .background { TodayGlassBackdrop() }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(
                        color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
                        radius: 12,
                        y: 12
                    )
                    .accessibilityLabel("查看旅程计划")

                    TodayQuickActionsBar(
                        isExpanded: $isQuickActionsExpanded,
                        activeAction: activeQuickAction,
                        isReloading: isReloading || isRouteLoading,
                        onAction: { action in
                            handleQuickAction(action, pois: pois)
                        },
                        onExpansionChanged: { isExpanded in
                            guard isExpanded else { return }
                            fitAll(pois: pois)
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func handleQuickAction(_ action: TodayQuickAction, pois: [TravelCardSnapshot]) {
        switch action {
        case .addCompanion:
            activeQuickAction = .addCompanion
            showsSharingSheet = true
        case .tripSelection:
            activeQuickAction = .tripSelection
            showsTripPicker = true
        case .reload:
            guard !isReloading else { return }
            activeQuickAction = .reload
            isReloading = true
            routeRefreshID &+= 1
            Task {
                async let retry: Void = syncEngine.retry()
                // 本地数据已是最新时，retry() 会立即返回；至少显示一整圈旋转，避免动画只闪动一帧。
                try? await Task.sleep(for: .seconds(0.75))
                await retry
                fitAll(pois: pois)
                isReloading = false
                if !isRouteLoading {
                    clearQuickAction(.reload)
                }
            }
        }
    }

    private func updateRouteLoading(_ isLoading: Bool) {
        guard isRouteLoading != isLoading else { return }
        isRouteLoading = isLoading
        if isLoading {
            activeQuickAction = .reload
        } else if !isReloading {
            clearQuickAction(.reload)
        }
    }

    private func updatePOIOverlayVisibility(
        isMapMoving: Bool,
        hasVisiblePOI: Bool
    ) {
        guard !isTimelineSwitching else { return }
        guard isMapViewportMoving != isMapMoving || hasVisiblePOIInMap != hasVisiblePOI else {
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            isMapViewportMoving = isMapMoving
            hasVisiblePOIInMap = hasVisiblePOI
        }
    }

    private func clearQuickAction(_ action: TodayQuickAction) {
        guard activeQuickAction == action else { return }
        activeQuickAction = nil
    }

    private func mapHeaderTitle(for day: TripDaySnapshot, currentIndex: Int, baseIndex: Int) -> String {
        if let dateText = monthDayChineseLabel(for: day) {
            if currentIndex == baseIndex, let weekday = weekdayLabel(for: day), !weekday.isEmpty {
                return "今日 \(weekday)"
            }
            return dateText
        }
        guard let date = Self.dayFormatter.date(from: day.date) else { return day.date }
        let fallback = Self.displayFormatter.string(from: date)
        if currentIndex == baseIndex, let weekday = weekdayLabel(for: day), !weekday.isEmpty {
            return "今日 \(weekday)"
        }
        return fallback
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

    private func selectDay(
        days: [TripDaySnapshot],
        index: Int,
        keepsPOIOverlayVisible: Bool = false
    ) {
        guard days.indices.contains(index) else { return }
        if keepsPOIOverlayVisible {
            isTimelineSwitching = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                isTimelineSwitching = false
                isMapViewportMoving = false
            }
        }
        hasCenteredOnPOIs = false
        selectedPOIIndex = 0
        expandedPOICardID = nil
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
    private func poiSwiper(
        pois: [TravelCardSnapshot],
        days: [TripDaySnapshot],
        currentDayIndex: Int,
        userLocation: CLLocationCoordinate2D?
    ) -> some View {
        let fallbackCardWidth = min(390, max(0, UIScreen.main.bounds.width - 40))
        // Each page retains a small trailing gutter. Besides visually
        // separating adjacent cards while swiping, this keeps the resting
        // card aligned with the 20pt screen margin.
        let itemSpacing: CGFloat = 12
        let itemWidth = max(0, fallbackCardWidth - itemSpacing)
        let currentCard = pois.indices.contains(clampedIndex(pois: pois)) ? pois[clampedIndex(pois: pois)] : nil
        let isExpanded = currentCard.map { expandedPOICardID == $0.id } ?? false
        let swiperHeight = POICard.height(for: itemWidth, card: currentCard, isExpanded: isExpanded)
        let selection = Binding<Int>(
            get: { clampedIndex(pois: pois) },
            set: { index in
                guard pois.indices.contains(index), selectedPOIIndex != index else { return }
                selectedPOIIndex = index
                focus(pois: pois, index: index)
            }
        )
        TabView(selection: selection) {
            ForEach(Array(pois.enumerated()), id: \.element.id) { index, card in
                POICard(
                    card: card,
                    index: index,
                    width: itemWidth,
                    userLocation: userLocation,
                    isExpanded: expandedPOICardID == card.id,
                    onToggleExpanded: {
                        withAnimation(.snappy(duration: 0.28)) {
                            expandedPOICardID = expandedPOICardID == card.id ? nil : card.id
                        }
                    }
                )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focus(pois: pois, index: index)
                    }
                    .frame(
                        width: fallbackCardWidth,
                        height: swiperHeight,
                        alignment: .center
                    )
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: fallbackCardWidth, height: swiperHeight)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          poiSwipeStartIndex == nil else { return }
                    poiSwipeStartIndex = clampedIndex(pois: pois)
                }
                .onEnded { value in
                    defer { poiSwipeStartIndex = nil }
                    guard value.translation.width < -50,
                          poiSwipeStartIndex == pois.count - 1 else { return }
                    selectDay(days: days, index: currentDayIndex + 1)
                }
        )
    }

    /// 将 POI 定锚在地图顶部控件与底部日期/景点卡之间的可见区域中点。
    private func poiFocusBottomInset(
        for pois: [TravelCardSnapshot],
        showsPOIOverlay: Bool
    ) -> CGFloat {
        guard showsPOIOverlay else { return 112 }
        let cardWidth = min(390, max(0, UIScreen.main.bounds.width - 40)) - 12
        let selectedCard = pois.indices.contains(clampedIndex(pois: pois))
            ? pois[clampedIndex(pois: pois)]
            : nil
        let isExpanded = selectedCard.map { expandedPOICardID == $0.id } ?? false
        return 112 + 8 + 39 + POICard.height(
            for: cardWidth,
            card: selectedCard,
            isExpanded: isExpanded
        )
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
                categorySymbolName: card.kind.systemImage,
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

    private func timelineLabel(for day: TripDaySnapshot, isToday: Bool) -> String {
        guard let date = Self.dayFormatter.date(from: day.date) else { return day.date }
        guard let weekday = weekdayLabel(from: date), !weekday.isEmpty else { return day.date }
        if isToday { return "今日 \(weekday)" }
        return "\(Self.timelineNumericFormatter.string(from: date)) \(weekday)"
    }

    private func weekdayLabel(for day: TripDaySnapshot) -> String? {
        guard let date = Self.dayFormatter.date(from: day.date) else { return nil }
        return weekdayLabel(from: date)
    }

    private func weekdayLabel(from date: Date) -> String? {
        let symbol = Self.weekdaySymbols[
            max(0, min(6, Self.utcCalendar.component(.weekday, from: date) - 1))
        ]
        return symbol
    }

    private func monthDayChineseLabel(for day: TripDaySnapshot) -> String? {
        guard let date = Self.dayFormatter.date(from: day.date) else { return nil }
        return monthDayChineseLabel(for: date)
    }

    private func monthDayChineseLabel(for date: Date) -> String? {
        let components = Self.utcCalendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return nil }
        return "\(chineseNumber(month))月\(chineseDayWithLeadingZero(day))"
    }

    private func chineseDayWithLeadingZero(_ value: Int) -> String {
        guard (1...31).contains(value) else { return String(value) }
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if value < 10 { return "〇\(digits[value])" }
        if value < 20 { return "十\(value == 10 ? "" : digits[value % 10])" }
        if value == 20 { return "廿" }
        if value < 30 {
            return "廿\(digits[value - 20])"
        }
        if value == 30 { return "三十" }
        if value == 31 { return "三十一" }
        return String(value)
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

    private static let timelineNumericFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM.dd"
        return formatter
    }()

    private static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

private enum TodayQuickAction: String, CaseIterable {
    case addCompanion
    case tripSelection
    case reload

    var iconName: String {
        switch self {
        case .addCompanion: "icon-adduser-outline"
        case .tripSelection: "icon-plan-outline"
        case .reload: "icon-reload-outline"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .addCompanion: "邀请同行人"
        case .tripSelection: "选择行程"
        case .reload: "重新同步"
        }
    }
}

private struct TodayQuickActionsBar: View {
    @Binding var isExpanded: Bool
    let activeAction: TodayQuickAction?
    let isReloading: Bool
    let onAction: (TodayQuickAction) -> Void
    let onExpansionChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: isExpanded ? 8 : 0) {
            expandButton

            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(TodayQuickAction.allCases, id: \.self) { action in
                        actionButton(action)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(width: 48, height: isExpanded ? 204 : 48, alignment: .top)
        .background {
            TodayGlassBackdrop()
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.3), value: isExpanded)
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }

    private var expandButton: some View {
        Button {
            let willExpand = !isExpanded
            withAnimation(.snappy(duration: 0.3)) {
                isExpanded = willExpand
            }
            onExpansionChanged(willExpand)
        } label: {
            Image("icon-dropdown-outline")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 40, height: 40)
                .background(
                    isExpanded ? Color.white.opacity(0.32) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 48, height: 48)
        .background {
            if isExpanded {
                TodayGlassBackdrop()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
            }
        }
        .shadow(
            color: isExpanded
                ? Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1)
                : .clear,
            radius: 12,
            y: 12
        )
        .zIndex(1)
        .accessibilityLabel(isExpanded ? "收起功能栏" : "展开功能栏")
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
    }

    private func actionButton(_ action: TodayQuickAction) -> some View {
        Button {
            guard action != .reload || !isReloading else { return }
            onAction(action)
        } label: {
            Image(action.iconName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(action == .reload && isReloading ? 360 : 0))
                .animation(
                    action == .reload && isReloading
                        ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.2),
                    value: isReloading
                )
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color(red: 1, green: 110 / 255, blue: 0))
                        .opacity(activeAction == action ? 1 : 0)
                )
                .animation(.easeInOut(duration: 0.2), value: activeAction)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityAddTraits(activeAction == action ? .isSelected : [])
    }
}

private struct TodayGlassBackdrop: View {
    var body: some View {
        ZStack {
            AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.1)
            Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
                .opacity(0.4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Horizontally scrollable day rail placed directly above the POI swiper. It
/// deliberately shares the swiper's visibility condition, so expanding the
/// action drawer moves both pieces away together.
private struct TodayDateTimeline: View {
    private enum PinnedTodaySide {
        case leading
        case trailing
    }

    let days: [TripDaySnapshot]
    let selectedIndex: Int
    let todayIndex: Int
    let width: CGFloat
    let label: (TripDaySnapshot, Bool) -> String
    let onSelect: (Int) -> Void
    @State private var todayFrame: CGRect = .null
    @State private var chipFrames: [UUID: CGRect] = [:]
    /// Local visual selection is updated at the exact moment the rail
    /// settles, rather than waiting for the parent map/card view to redraw.
    @State private var anchoredIndex: Int?
    /// `ScrollView` also emits idle phases for `scrollTo` during creation.
    /// Only a preceding direct drag is allowed to choose a new day.
    @State private var isUserDraggingTimeline = false
    @State private var hasSettledCurrentTimelineDrag = false

    private let coordinateSpaceName = "today-date-timeline-viewport"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let isSelected = index == (anchoredIndex ?? selectedIndex)
                        let isToday = index == todayIndex
                        Button {
                            onSelect(index)
                        } label: {
                            timelineChip(for: day, index: index, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(day, isToday))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(day.id)
                    }
                }
                // Extra end room lets the first and last date snap to the
                // central anchor as well, instead of stopping at a side edge.
                .padding(.horizontal, max(8, width / 2))
            }
            .coordinateSpace(name: coordinateSpaceName)
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting:
                    isUserDraggingTimeline = true
                    hasSettledCurrentTimelineDrag = false
                case .decelerating:
                    // Intercept real inertial scrolling as soon as the finger
                    // lifts, rather than waiting for a long coast.
                    guard isUserDraggingTimeline, !hasSettledCurrentTimelineDrag else { return }
                    hasSettledCurrentTimelineDrag = true
                    settleDateUnderAnchor(using: scrollProxy, settlesImmediately: true)
                case .idle:
                    guard isUserDraggingTimeline else { return }
                    if !hasSettledCurrentTimelineDrag {
                        settleDateUnderAnchor(using: scrollProxy)
                    }
                    isUserDraggingTimeline = false
                    hasSettledCurrentTimelineDrag = false
                case .animating:
                    // Programmatic centering must not write a date selection.
                    break
                }
            }
            // The white point is a stable anchor; the selected date scrolls
            // beneath it instead of carrying the point along.
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 4)
            }
            .overlay(alignment: .leading) {
                if pinnedTodaySide == .leading {
                    leadingPinnedTodayOverlay
                }
            }
            .overlay(alignment: .trailing) {
                if pinnedTodaySide == .trailing {
                    pinnedTodayButton(hasLeadingShadow: false)
                        .padding(.trailing, 7)
                }
            }
            .onAppear {
                anchoredIndex = selectedIndex
                centerDate(at: selectedIndex, using: scrollProxy, animated: false)
            }
            .onChange(of: selectedIndex) {
                anchoredIndex = selectedIndex
                centerDate(at: selectedIndex, using: scrollProxy, animated: true)
            }
        }
        .onPreferenceChange(TodayTimelineTodayFramePreferenceKey.self) {
            todayFrame = $0
        }
        .onPreferenceChange(TodayTimelineChipFramesPreferenceKey.self) {
            chipFrames = $0
        }
        .frame(width: width, height: 47)
        .background {
            ZStack {
                AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.12)
                Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.72)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.05), lineWidth: 1)
            }
    }

    private var pinnedTodaySide: PinnedTodaySide? {
        guard todayFrame != .null else { return nil }
        // Swap into the fixed button before the whole chip disappears, so
        // there is no moment where the way back to today is lost.
        let edgeThreshold: CGFloat = 48
        if todayFrame.maxX < edgeThreshold { return .leading }
        if todayFrame.minX > width - edgeThreshold { return .trailing }
        return nil
    }

    private var leadingPinnedTodayOverlay: some View {
        ZStack(alignment: .leading) {
            // The fixed button owns the rail's leading area. Do not let
            // scrolling labels show through the gap before the button.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.98), location: 0),
                    .init(color: Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.98), location: 0.74),
                    .init(color: Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 132, height: 47)

            pinnedTodayButton(hasLeadingShadow: true)
                .padding(.leading, 7)
        }
        .frame(width: 132, height: 47, alignment: .leading)
    }

    private func pinnedTodayButton(hasLeadingShadow: Bool) -> some View {
        Button {
            onSelect(todayIndex)
        } label: {
            Text(label(days[todayIndex], true))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .shadow(
            color: hasLeadingShadow
                ? Color.black.opacity(0.5)
                : .clear,
            radius: 12,
            y: 8
        )
        .accessibilityLabel("返回今天")
    }

    private func centerDate(
        at index: Int,
        using scrollProxy: ScrollViewProxy,
        animated: Bool,
        settlesImmediately: Bool = false
    ) {
        guard days.indices.contains(index) else { return }
        let scroll = {
            scrollProxy.scrollTo(days[index].id, anchor: .center)
        }
        if animated {
            if settlesImmediately {
                withAnimation(.easeOut(duration: 0.18)) { scroll() }
            } else {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.92)) { scroll() }
            }
        } else {
            DispatchQueue.main.async { scroll() }
        }
    }

    private func settleDateUnderAnchor(
        using scrollProxy: ScrollViewProxy,
        settlesImmediately: Bool = false
    ) {
        guard days.allSatisfy({ chipFrames[$0.id] != nil }) else { return }
        let anchorX = width / 2
        let candidates = days.compactMap { day -> (day: TripDaySnapshot, frame: CGRect)? in
            guard let frame = chipFrames[day.id] else { return nil }
            return (day, frame)
        }
        guard let closest = candidates.min(by: {
            abs($0.frame.midX - anchorX) < abs($1.frame.midX - anchorX)
        }), let index = days.firstIndex(where: { $0.id == closest.day.id }) else { return }

        anchoredIndex = index
        if index != selectedIndex {
            onSelect(index)
            centerDate(
                at: index,
                using: scrollProxy,
                animated: true,
                settlesImmediately: settlesImmediately
            )
        } else if abs(closest.frame.midX - anchorX) > 1 {
            // `scrollTo` makes the visual anchoring deterministic even when
            // the drag ends between two labels.
            centerDate(
                at: index,
                using: scrollProxy,
                animated: true,
                settlesImmediately: settlesImmediately
            )
        }
    }

    @ViewBuilder
    private func timelineChip(for day: TripDaySnapshot, index: Int, isSelected: Bool) -> some View {
        let isToday = index == todayIndex
        let activeTextColor = isSelected ? Color.white : Color.white.opacity(0.64)

        Text(label(day, isToday))
            .font(.system(size: 16, weight: .medium))
            .lineSpacing(0)
            .lineLimit(1)
            .frame(height: 16)
            .foregroundStyle(activeTextColor)
            .padding(.horizontal, 12)
            .frame(height: 39)
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(coordinateSpaceName))
                    Color.clear
                        .preference(
                            key: TodayTimelineChipFramesPreferenceKey.self,
                            value: [day.id: frame]
                        )
                        .preference(
                            key: TodayTimelineTodayFramePreferenceKey.self,
                            value: isToday ? frame : .null
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

@MainActor
private final class TodayUserLocationProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let locationManager = CLLocationManager()
    private var hasStarted = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 100
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else {
            return
        }
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        // 距离展示无需持续高频定位；获得一条可用位置即可停止。
        manager.stopUpdatingLocation()
    }
}

private struct TodayTimelineTodayFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect { .null }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .null { value = next }
    }
}

private struct TodayTimelineChipFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct POICard: View {
    let card: TravelCardSnapshot
    let index: Int
    let width: CGFloat
    let userLocation: CLLocationCoordinate2D?
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    private static let summaryHeight: CGFloat = 78
    private static let imageAspectRatio: CGFloat = 16.0 / 9.0
    private static let horizontalPadding: CGFloat = 12
    private static let summarySpacing: CGFloat = 4
    private static let verticalPadding: CGFloat = 12
    private static let expandedTopPadding: CGFloat = 12
    private static let expandedBottomPadding: CGFloat = 10
    private static let detailRowSpacing: CGFloat = 14
    private static let detailRowHeight: CGFloat = 34
    private static let detailLocationHeight: CGFloat = 74
    private static let detailActionHeight: CGFloat = 30
    private static let detailActionWidth: CGFloat = 114
    private static let detailActionTopSpacing: CGFloat = 8
    private static let detailActionColor = Color(
        red: 180 / 255,
        green: 180 / 255,
        blue: 180 / 255
    )

    static func height(for cardWidth: CGFloat, card: TravelCardSnapshot?, isExpanded: Bool) -> CGFloat {
        let contentWidth = max(0, cardWidth - horizontalPadding)
        let baseHeight = (contentWidth / imageAspectRatio) + summaryHeight + summarySpacing + verticalPadding
        guard isExpanded else { return baseHeight }
        return baseHeight + detailSectionHeight(for: card)
    }

    private var imageHeight: CGFloat {
        max(0, (width - Self.horizontalPadding) / Self.imageAspectRatio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            coverImage
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .aspectRatio(Self.imageAspectRatio, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            poiSummary
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.summaryHeight,
                    maxHeight: Self.summaryHeight
                )

            if isExpanded {
                expandedDetails
                    .padding(.horizontal, 8)
                    .padding(.top, Self.expandedTopPadding)
                    .padding(.bottom, Self.expandedBottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: width, height: Self.height(for: width, card: card, isExpanded: isExpanded), alignment: .topLeading)
        .background {
            ZStack {
                AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.12)
                Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.72)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        }
        // Keep one persistent action at the card's bottom-right corner. The
        // card grows upward from its bottom edge, so its label can morph
        // between expand/collapse without jumping to a different row.
        .overlay(alignment: .bottomTrailing) {
            detailAction
                .padding(.trailing, 8)
                .padding(.bottom, Self.detailActionTopSpacing)
        }
        .accessibilityLabel("第 \(index + 1) 个地点，\(card.title)，\(timeText)")
    }

    private static func detailSectionHeight(for card: TravelCardSnapshot?) -> CGFloat {
        var rowHeights: [CGFloat] = []
        if let businessHours = businessHoursText(for: card), !businessHours.isEmpty {
            rowHeights.append(detailRowHeight)
        }
        if let location = locationText(for: card), !location.isEmpty {
            rowHeights.append(detailLocationHeight)
        }
        if let phone = phoneText(for: card), !phone.isEmpty {
            rowHeights.append(detailRowHeight)
        }
        return expandedTopPadding
            + expandedBottomPadding
            + summarySpacing
            + rowHeights.reduce(0, +)
            + detailRowSpacing * CGFloat(max(0, rowHeights.count - 1))
            + detailActionTopSpacing
            + detailActionHeight
    }

    private static func locationText(for card: TravelCardSnapshot?) -> String? {
        let value = card?.place?.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        let name = card?.place?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private static func phoneText(for card: TravelCardSnapshot?) -> String? {
        let value = card?.bookingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func businessHoursText(for card: TravelCardSnapshot?) -> String? {
        let value = card?.place?.businessHours?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var poiSummary: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))
                .overlay(
                    Circle()
                        .stroke(Color(red: 1, green: 110 / 255, blue: 0), lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 22, weight: .medium))
                        .tracking(0)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .lineSpacing(0)
                }

                HStack(spacing: 8) {
                    Text(timeText)
                        .font(.custom("Inter", size: 14).weight(.medium))
                        .foregroundStyle(Color(red: 180 / 255, green: 180 / 255, blue: 180 / 255))
                        .lineSpacing(0)

                    Spacer(minLength: 8)
                }
                // Reserve the persistent bottom-right action's footprint
                // while the card is collapsed.
                .padding(.trailing, 116)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: Self.detailRowSpacing) {
            if let businessHours = Self.businessHoursText(for: card) {
                // 展开态展示的是 POI 营业时间，不复用收起态的行程到达/离开时间。
                detailRow(
                    iconName: "icon-poi-time-outline",
                    text: businessHours
                )
            }

            if let locationText = Self.locationText(for: card) {
                locationDetailRow(locationText)
            }

            if let phoneText = Self.phoneText(for: card) {
                phoneDetailRow(phoneText)
            }

        }
    }

    private func locationDetailRow(_ locationText: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image("icon-poi-location-outline")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(locationText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let distanceText {
                    Text(distanceText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 180 / 255, green: 180 / 255, blue: 180 / 255))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: Self.detailLocationHeight, alignment: .leading)
    }

    private var distanceText: String? {
        guard let userLocation,
              let latitude = card.place?.latitude,
              let longitude = card.place?.longitude else {
            return nil
        }
        let distance = CLLocation(
            latitude: userLocation.latitude,
            longitude: userLocation.longitude
        ).distance(from: CLLocation(latitude: latitude, longitude: longitude))
        return distance >= 1_000
            ? String(format: "距你 %.1f km", distance / 1_000)
            : "距你 %.0f m"
    }

    @ViewBuilder
    private func phoneDetailRow(_ phoneText: String) -> some View {
        if let phoneURL = Self.phoneURL(for: phoneText) {
            Link(destination: phoneURL) {
                detailRow(
                    iconName: "icon-poi-phone-outline",
                    text: phoneText
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("点击拨打商家电话")
        } else {
            detailRow(
                iconName: "icon-poi-phone-outline",
                text: phoneText
            )
        }
    }

    private static func phoneURL(for phoneText: String) -> URL? {
        let allowedCharacters = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "+*#,"))
        let dialString = String(phoneText.unicodeScalars.filter(allowedCharacters.contains))
        guard !dialString.isEmpty else { return nil }
        return URL(string: "tel://\(dialString)")
    }

    private var detailAction: some View {
        Button(action: onToggleExpanded) {
            ZStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .medium))
                    Text("收起资讯")
                        .font(.system(size: 16, weight: .medium))
                        .lineSpacing(0)
                }
                .foregroundStyle(Self.detailActionColor)
                .frame(height: Self.detailActionHeight)
                .frame(width: Self.detailActionWidth, alignment: .leading)
                .opacity(isExpanded ? 1 : 0)

                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                    Text("展开资讯")
                        .font(.system(size: 16, weight: .medium))
                        .lineSpacing(0)
                }
                .foregroundStyle(Self.detailActionColor)
                .frame(height: Self.detailActionHeight)
                .frame(width: Self.detailActionWidth, alignment: .leading)
                .opacity(isExpanded ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.18), value: isExpanded)
        }
        .frame(width: Self.detailActionWidth, height: Self.detailActionHeight, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起资讯" : "展开资讯")
    }

    private func detailRow(
        iconName: String,
        text: String,
        lineLimit: Int = 1,
        rowHeight: CGFloat = Self.detailRowHeight
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(iconName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)

            Text(text)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: rowHeight, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: rowHeight, alignment: .center)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let url = CardImageURL.resolve(card.images?.first) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    coverPlaceholder
                }
            }
            .clipped()
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 67 / 255, green: 67 / 255, blue: 67 / 255),
                    Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: card.kind.systemImage)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        if let endAt = card.endAt { return "\(formatter.string(from: card.startAt))~\(formatter.string(from: endAt))" }
        return formatter.string(from: card.startAt)
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
