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
    @State private var inviteURL: URL?
    @State private var showsTripPicker = false
    @State private var inviteErrorMessage: String?
    @State private var activeQuickAction: TodayQuickAction?
    @State private var isQuickActionsExpanded = false
    @State private var isReloading = false
    @State private var isRouteLoading = false
    @State private var routeRefreshID = 0

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
        .sheet(item: $detailCard) { card in
            TodayCardDetailSheet(card: card, linkHandler: linkHandler)
        }
        .sheet(isPresented: Binding(
            get: { inviteURL != nil },
            set: {
                if !$0 {
                    inviteURL = nil
                    clearQuickAction(.addCompanion)
                }
            }
        )) {
            if let inviteURL {
                ShareLink(item: inviteURL, message: Text("邀请你共同编辑我的旅行行程")) {
                    Label("分享共同编辑邀请", systemImage: "person.badge.plus")
                        .font(.headline)
                }
                .padding()
                .presentationDetents([.height(140)])
            }
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
        .alert("无法分享邀请", isPresented: Binding(
            get: { inviteErrorMessage != nil },
            set: {
                if !$0 {
                    inviteErrorMessage = nil
                    clearQuickAction(.addCompanion)
                }
            }
        )) {
            Button("好", role: .cancel) {
                inviteErrorMessage = nil
                clearQuickAction(.addCompanion)
            }
        } message: {
            Text(inviteErrorMessage ?? "")
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
        ZStack {
            MapLibreTodayMapCanvas(
                points: mapPoints(pois: pois),
                // A selected map marker is the visual counterpart of the
                // visible POI card. When the action drawer covers that card,
                // keep every marker compact and neutral instead.
                selectedIndex: isQuickActionsExpanded ? nil : clampedIndex(pois: pois),
                cameraFocus: cameraFocus,
                cameraRequestID: cameraRequestID,
                overviewBottomInset: isQuickActionsExpanded ? 112 : 240,
                routeRefreshID: routeRefreshID
            ) { isLoading in
                // UIViewRepresentable 更新期间不能同步写入 SwiftUI 状态。
                DispatchQueue.main.async {
                    updateRouteLoading(isLoading)
                }
            }
            .ignoresSafeArea()
            .simultaneousGesture(daySwipeGesture(days: days, currentIndex: currentIndex))

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
                mapHeader(for: day, pois: pois, currentIndex: currentIndex, baseIndex: baseIndex)
                Spacer()
                if !pois.isEmpty && !isQuickActionsExpanded {
                    poiSwiper(pois: pois)
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
        for day: TripDaySnapshot,
        pois: [TravelCardSnapshot],
        currentIndex: Int,
        baseIndex: Int
    ) -> some View {
        ZStack(alignment: .top) {
            Text(mapHeaderTitle(for: day, currentIndex: currentIndex, baseIndex: baseIndex))
                .font(.custom("PingFangTC-Semibold", size: 24))
                .tracking(0.024)
                .frame(height: 36)
                .foregroundStyle(.white)

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
            Task {
                inviteURL = await syncEngine.createShareInvite()
                if inviteURL == nil {
                    inviteErrorMessage = "当前旅程暂时无法创建共同编辑邀请。"
                }
            }
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

    private func clearQuickAction(_ action: TodayQuickAction) {
        guard activeQuickAction == action else { return }
        activeQuickAction = nil
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
            set: { index in
                guard pois.indices.contains(index), selectedPOIIndex != index else { return }
                selectedPOIIndex = index
                focus(pois: pois, index: index)
            }
        )
        GeometryReader { proxy in
            let cardWidth = min(390, max(0, proxy.size.width - 40))
            TabView(selection: selection) {
                ForEach(Array(pois.enumerated()), id: \.element.id) { index, card in
                    POICard(
                        card: card,
                        index: index,
                        width: cardWidth
                    )
                        .contentShape(Rectangle())
                        .onTapGesture { detailCard = card }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: proxy.size.width, height: 248)
        }
        .frame(height: 248)
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

private struct POICard: View {
    let card: TravelCardSnapshot
    let index: Int
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverImage
                .frame(maxWidth: .infinity)
                .frame(height: 154)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            poiSummary
                .padding(.horizontal, 8)
                .padding(.top, 11)
                .padding(.bottom, 7)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: width, height: 248, alignment: .topLeading)
        .background {
            ZStack {
                AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.45)
                Color(red: 67 / 255, green: 67 / 255, blue: 67 / 255).opacity(0.4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityLabel("第 \(index + 1) 个地点，\(card.title)，\(timeText)")
    }

    private var poiSummary: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 22, weight: .medium))
                        .tracking(0)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .lineSpacing(0)

                    Circle()
                        .fill(Color(red: 48 / 255, green: 214 / 255, blue: 76 / 255))
                        .frame(width: 8, height: 8)
                }

                HStack(spacing: 8) {
                    Text(timeText)
                        .font(.custom("Inter", size: 14).weight(.medium))
                        .foregroundStyle(Color(red: 180 / 255, green: 180 / 255, blue: 180 / 255))
                        .lineSpacing(0)

                    Spacer(minLength: 8)

                    Text("詳細資訊")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
