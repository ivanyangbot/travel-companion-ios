import MapKit
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// “今日”页：全屏地图按时间顺序连线今日 POI，底部 swiper 横滑切换并点击查看详情。
struct TodayView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var appleSignIn: AppleSignInStore
    @Binding var section: JourneyView.Section
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var agentSessionStore: AgentV2SessionStore
    @EnvironmentObject private var agentRunState: AgentV2RunState
    @StateObject private var linkHandler = ExternalLinkHandler()
    @State private var selectedPOIIndex = 0
    @State private var cameraFocus: CLLocationCoordinate2D?
    @State private var cameraFocusPointID: UUID?
    @State private var cameraRequestID = 0
    @State private var detailCard: TravelCardSnapshot?
    @State private var hasCenteredOnPOIs = false
    /// 相对于排序后 days 的当前选中索引；nil 表示跟随“今日”基准。
    @State private var selectedDayIndex: Int?
    @State private var weatherEntries: [TodayWeatherEntry] = []
    @State private var isPOIOverlayExpanded = true
    // Restored from the original home-page quick-action drawer. The current
    // down button now collapses the POI overlay and opens this menu in one tap.
    @State private var activeQuickAction: TodayQuickAction?
    @State private var showsSharingSheet = false
    @State private var showsTripPicker = false
    @State private var tripBeingSelectedID: Int?
    @State private var isStartingNewTrip = false
    @State private var isPlanningNewTrip = false
    @State private var showsSignOutConfirmation = false
    @State private var signOutErrorMessage: String?
    @State private var isReloading = false
    @State private var expandedPOICardID: UUID?
    @State private var poiExpansionProgress: CGFloat = 0
    @State private var poiSwipeStartIndex: Int?
    @State private var poiSwipeStartExpansionProgress: CGFloat?
    @State private var poiSwipeTranslation: CGFloat = 0
    /// Window/global Y of the timeline's upper edge, used to keep map edge
    /// pins above the persistent timeline and POI card overlay.
    @State private var lastTimelineTopInGlobal: CGFloat?
    @StateObject private var userLocationProvider = TodayUserLocationProvider()

    var body: some View {
        Group {
            if isPlanningNewTrip {
                newTripAgentHome
            } else if let trip = syncEngine.trip, trip.isConfigured {
                let sorted = sortedDays(in: trip)
                if sorted.isEmpty {
                    agentHome
                } else {
                    let baseIndex = baseDayIndex(in: sorted)
                    let currentIndex = clampedDayIndex(sorted: sorted, baseIndex: baseIndex)
                    mapContent(days: sorted, currentIndex: currentIndex, baseIndex: baseIndex)
                }
            } else if syncEngine.trip == nil {
                switch syncEngine.status {
                case .failed(let message):
                    ContentUnavailableView("无法加载共享行程", systemImage: "wifi.exclamationmark", description: Text(message))
                case .loading, .syncing:
                    ProgressView("正在打开共享行程…")
                default:
                    // 没有生效的行程（地图不显示）时，首页直接复用 Agent 页
                    agentHome
                }
            } else {
                // 行程存在但未完成设置：同样展示 Agent 页引导规划
                agentHome
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
        .sheet(isPresented: Binding(
            get: { showsTripPicker },
            set: {
                showsTripPicker = $0
                if !$0 {
                    clearQuickAction(.tripSelection)
                    withAnimation(.snappy(duration: 0.28)) {
                        isPOIOverlayExpanded = true
                    }
                }
            }
        )) {
            TodayTripPickerSheet(
                trips: syncEngine.trips,
                selectedTripID: syncEngine.selectedTripID,
                tripBeingSelectedID: tripBeingSelectedID,
                isStartingNewTrip: isStartingNewTrip,
                onSelect: selectTripFromPicker,
                onCreate: startNewTripFromPicker,
                onDismiss: { showsTripPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
            .presentationBackground(PrimaryTabPalette.background)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled(tripBeingSelectedID != nil || isStartingNewTrip)
        }
        .alert("退出登录？", isPresented: Binding(
            get: { showsSignOutConfirmation },
            set: {
                showsSignOutConfirmation = $0
                if !$0 { clearQuickAction(.signOut) }
            }
        )) {
            Button("退出登录", role: .destructive) {
                if !appleSignIn.signOut() {
                    signOutErrorMessage = appleSignIn.errorMessage ?? "请稍后重试。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后将停止云端同步，仍可继续使用本地模式。")
        }
        .alert("无法退出登录", isPresented: Binding(
            get: { signOutErrorMessage != nil },
            set: { if !$0 { signOutErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { signOutErrorMessage = nil }
        } message: {
            Text(signOutErrorMessage ?? "")
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
        // 与旅程/账本/手书等主页一致的暗色底，保证空态与加载态不露出浅色背景。
        .preferredColorScheme(.dark)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
    }

    /// 无生效行程时的首页内容：首页专用 Agent 页（AgentHomeView，独立于
    /// Agent 工作台可单独调整），让用户直接开始对话规划。悬浮导航栏的
    /// 底部预留由 AgentHomeView 按欢迎页/对话页状态自行控制。
    private var agentHome: some View {
        AgentHomeView(syncEngine: syncEngine, appleSignIn: appleSignIn)
    }

    /// “新建一段旅行”进入的临时规划模式。当前旅行暂时保留，方便用户随时
    /// 返回；Agent 请求强制按 plan_new 发送，确认创建后才切换选中旅行。
    private var newTripAgentHome: some View {
        AgentHomeView(
            syncEngine: syncEngine,
            appleSignIn: appleSignIn,
            plansNewTrip: true,
            onCancelNewTripPlanning: cancelNewTripPlanning,
            onNewTripCreated: finishNewTripPlanning
        )
    }

    @ViewBuilder
    private func mapContent(days: [TripDaySnapshot], currentIndex: Int, baseIndex: Int) -> some View {
        let day = days[currentIndex]
        let pois = poiCards(in: day)
        let showsPOISwiper = !pois.isEmpty && isPOIOverlayExpanded
        let showsTimeline = pois.isEmpty || isPOIOverlayExpanded
        ZStack(alignment: .top) {
            MapLibreTodayMapCanvas(
                points: mapPoints(pois: pois),
                // A selected map marker is the visual counterpart of the
                // visible POI card. Keep every marker compact and neutral
                // while the user has collapsed the bottom overlay.
                selectedIndex: isPOIOverlayExpanded ? clampedIndex(pois: pois) : nil,
                cameraFocus: cameraFocus,
                cameraFocusPointID: cameraFocusPointID,
                cameraRequestID: cameraRequestID,
                // While the timeline is visible, its live frame is the bottom
                // pin boundary and follows card expansion. A date without POIs
                // keeps this boundary because its timeline remains on screen.
                timelineTopInGlobal: showsTimeline ? lastTimelineTopInGlobal : nil,
                overviewBottomInset: isPOIOverlayExpanded ? 240 : 112,
                routeRefreshID: 0
            ) { _ in
            } onViewportStateChanged: { _, _ in
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
                if showsTimeline {
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
                            selectDay(days: days, index: index)
                        }
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TodayTimelineTopInGlobalPreferenceKey.self,
                                    value: geometry.frame(in: .global).minY
                                )
                            }
                        }

                        if showsPOISwiper {
                            poiSwiper(
                                pois: pois,
                                days: days,
                                currentDayIndex: currentIndex,
                                userLocation: userLocationProvider.coordinate
                            )
                        }
                    }
                    .padding(.bottom, 112)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
        }
        .onPreferenceChange(TodayTimelineTopInGlobalPreferenceKey.self) { top in
            guard let top, top.isFinite, top > 0 else { return }
            if lastTimelineTopInGlobal.map({ abs($0 - top) > 0.5 }) ?? true {
                lastTimelineTopInGlobal = top
            }
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
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .simultaneousGesture(daySwipeGesture(days: days, currentIndex: currentIndex))

            HStack(alignment: .top, spacing: 0) {
                TodayHomeDropdownMenu(
                    isPOIOverlayExpanded: $isPOIOverlayExpanded,
                    activeAction: activeQuickAction,
                    isReloading: isReloading,
                    isAuthenticated: appleSignIn.isAuthenticated,
                    onAction: { action in handleQuickAction(action, pois: pois) },
                    onOverlayExpansionChanged: { isExpanded in
                        guard isExpanded else { return }
                        fitAll(pois: pois)
                    }
                )

                Spacer(minLength: 0)

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
            Task {
                async let retry: Void = syncEngine.retry()
                // Preserve the old drawer's visible full-turn reload animation.
                try? await Task.sleep(for: .seconds(0.75))
                await retry
                fitAll(pois: pois)
                isReloading = false
                clearQuickAction(.reload)
            }
        case .signOut:
            guard appleSignIn.isAuthenticated else { return }
            activeQuickAction = .signOut
            showsSignOutConfirmation = true
        }
    }

    private func clearQuickAction(_ action: TodayQuickAction) {
        guard activeQuickAction == action else { return }
        activeQuickAction = nil
    }

    /// Switches trips without dismissing the picker prematurely, so the selected
    /// row can provide immediate progress feedback while cached/network state loads.
    private func selectTripFromPicker(_ summary: TripSummary) {
        guard tripBeingSelectedID == nil, !isStartingNewTrip else { return }
        guard summary.id != syncEngine.selectedTripID else {
            showsTripPicker = false
            return
        }
        tripBeingSelectedID = summary.id
        resetMapSelection()
        Task {
            await syncEngine.selectTrip(summary.id)
            tripBeingSelectedID = nil
            showsTripPicker = false
        }
    }

    /// Starts a new planning context while retaining the selected trip until
    /// creation succeeds, allowing the user to return to the current map.
    private func startNewTripFromPicker() {
        guard tripBeingSelectedID == nil, !isStartingNewTrip else { return }
        isStartingNewTrip = true
        resetMapSelection()
        agentRunState.clearTransientState()
        agentSessionStore.startNewSession()
        withAnimation(.snappy(duration: 0.32)) {
            isPlanningNewTrip = true
            showsTripPicker = false
        }
        isStartingNewTrip = false
    }

    private func cancelNewTripPlanning() {
        agentRunState.clearTransientState()
        agentSessionStore.startNewSession()
        withAnimation(.snappy(duration: 0.32)) {
            isPlanningNewTrip = false
        }
    }

    private func finishNewTripPlanning() {
        withAnimation(.snappy(duration: 0.32)) {
            isPlanningNewTrip = false
        }
    }

    private func resetMapSelection() {
        selectedDayIndex = nil
        selectedPOIIndex = 0
        cameraFocus = nil
        cameraFocusPointID = nil
        weatherEntries = []
        expandedPOICardID = nil
        poiExpansionProgress = 0
    }

    private func mapHeaderTitle(for day: TripDaySnapshot, currentIndex: Int, baseIndex: Int) -> String {
        ItineraryListPresentation.timelineLabel(day, currentIndex == baseIndex)
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
        expandedPOICardID = nil
        poiExpansionProgress = 0
        poiSwipeStartIndex = nil
        poiSwipeStartExpansionProgress = nil
        poiSwipeTranslation = 0
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
        // Match the timeline's visible width exactly. Card-to-card spacing is
        // part of the paging stride instead of being subtracted from the card.
        let cardWidth = min(390, max(0, UIScreen.main.bounds.width - 40))
        let pageSpacing: CGFloat = 12
        let pageStride = cardWidth + pageSpacing
        let currentCard = pois.indices.contains(clampedIndex(pois: pois)) ? pois[clampedIndex(pois: pois)] : nil
        let currentExpansionProgress = currentCard.map {
            expandedPOICardID == $0.id ? poiExpansionProgress : 0
        } ?? 0
        // Keep the underlying paging container at its starting height while
        // the finger is down. Only the card itself follows the interactive
        // progress, preventing UIKit's paging scroll view from being resized
        // on every horizontal-drag frame.
        let containerExpansionProgress = poiSwipeStartExpansionProgress ?? currentExpansionProgress
        let containerCard = poiSwipeStartIndex.flatMap { startIndex in
            pois.indices.contains(startIndex) ? pois[startIndex] : nil
        } ?? currentCard
        let swiperHeight = POICard.height(
            for: cardWidth,
            card: containerCard,
            expansionProgress: containerExpansionProgress
        )
        let settledIndex = clampedIndex(pois: pois)
        HStack(spacing: 0) {
            ForEach(Array(pois.enumerated()), id: \.element.id) { index, card in
                POICard(
                    card: card,
                    index: index,
                    width: cardWidth,
                    userLocation: userLocation,
                    expansionProgress: expandedPOICardID == card.id ? poiExpansionProgress : 0,
                    onToggleExpanded: {
                        let willExpand = expandedPOICardID != card.id || poiExpansionProgress < 0.5
                        withAnimation(.smooth(duration: 0.28)) {
                            expandedPOICardID = willExpand ? card.id : nil
                            poiExpansionProgress = willExpand ? 1 : 0
                        }
                    }
                )
                    .contentShape(Rectangle())
                    // Buttons and links inside POICard keep their own actions;
                    // tapping the remaining card surface recenters the map.
                    .onTapGesture { focus(pois: pois, index: index) }
                    .frame(
                        width: pageStride,
                        height: swiperHeight,
                        // Expanded and collapsed cards share one stable
                        // baseline while the page transition is interactive.
                        // Center alignment made the shorter destination card
                        // jump downward when the swiper height collapsed.
                        alignment: .bottomLeading
                    )
            }
        }
        .frame(
            width: pageStride * CGFloat(pois.count),
            height: swiperHeight,
            alignment: .leading
        )
        .offset(x: -CGFloat(settledIndex) * pageStride + poiSwipeTranslation)
        .frame(width: cardWidth, height: swiperHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        // The pager keeps a stable height while the finger is down. Its
        // vertical settling animation starts only after the gesture ends.
        .animation(
            poiSwipeStartIndex == nil ? .smooth(duration: 0.28) : nil,
            value: swiperHeight
        )
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }

                    if poiSwipeStartIndex == nil {
                        let startIndex = clampedIndex(pois: pois)
                        poiSwipeStartIndex = startIndex
                        if pois.indices.contains(startIndex),
                           expandedPOICardID == pois[startIndex].id {
                            poiSwipeStartExpansionProgress = poiExpansionProgress
                        } else {
                            poiSwipeStartExpansionProgress = nil
                        }
                    }

                    let startIndex = poiSwipeStartIndex ?? settledIndex
                    var translation = value.translation.width
                    if (startIndex == 0 && translation > 0)
                        || (startIndex == pois.count - 1 && translation < 0) {
                        translation *= 0.38
                    }

                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        poiSwipeTranslation = translation
                        if let startProgress = poiSwipeStartExpansionProgress {
                            let pageProgress = min(
                                1,
                                abs(value.translation.width) / max(1, pageStride)
                            )
                            poiExpansionProgress = startProgress * (1 - pageProgress)
                        }
                    }
                }
                .onEnded { value in
                    let startIndex = poiSwipeStartIndex ?? settledIndex
                    let startProgress = poiSwipeStartExpansionProgress
                    let actualTranslation = value.translation.width
                    let projectedTranslation = value.predictedEndTranslation.width
                    let movesForward = actualTranslation < -pageStride * 0.22
                        || projectedTranslation < -pageStride * 0.5
                    let movesBackward = actualTranslation > pageStride * 0.22
                        || projectedTranslation > pageStride * 0.5

                    var targetIndex = startIndex
                    if movesForward, startIndex < pois.count - 1 {
                        targetIndex += 1
                    } else if movesBackward, startIndex > 0 {
                        targetIndex -= 1
                    }

                    if targetIndex != startIndex {
                        withAnimation(.smooth(duration: 0.28)) {
                            selectedPOIIndex = targetIndex
                            poiSwipeTranslation = 0
                            poiSwipeStartIndex = nil
                            poiSwipeStartExpansionProgress = nil
                            expandedPOICardID = nil
                            poiExpansionProgress = 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            guard selectedPOIIndex == targetIndex else { return }
                            focus(pois: pois, index: targetIndex)
                        }
                    } else if movesForward,
                              startIndex == pois.count - 1,
                              currentDayIndex < days.count - 1 {
                        poiSwipeTranslation = 0
                        poiSwipeStartIndex = nil
                        poiSwipeStartExpansionProgress = nil
                        selectDay(days: days, index: currentDayIndex + 1)
                    } else if movesBackward,
                              startIndex == 0,
                              currentDayIndex > 0 {
                        poiSwipeTranslation = 0
                        poiSwipeStartIndex = nil
                        poiSwipeStartExpansionProgress = nil
                        selectDay(days: days, index: currentDayIndex - 1)
                    } else {
                        withAnimation(.smooth(duration: 0.22)) {
                            poiSwipeTranslation = 0
                            poiSwipeStartIndex = nil
                            poiSwipeStartExpansionProgress = nil
                            poiExpansionProgress = startProgress ?? poiExpansionProgress
                        }
                    }
                }
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

    private func fitAll(pois: [TravelCardSnapshot]) {
        guard !pois.isEmpty else { return }
        if pois.count == 1, let coordinate = coordinate(of: pois[0]) {
            cameraFocus = coordinate
            cameraFocusPointID = pois[0].id
        } else {
            cameraFocus = nil
            cameraFocusPointID = nil
        }
        cameraRequestID &+= 1
    }

    private func focus(pois: [TravelCardSnapshot], index: Int) {
        guard pois.indices.contains(index), let coordinate = coordinate(of: pois[index]) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraFocus = coordinate
            cameraFocusPointID = pois[index].id
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

/// Original animated home quick-action drawer, coupled to the current POI
/// overlay toggle so one tap collapses the cards and reveals the menu.
private enum TodayQuickAction: String, CaseIterable {
    case addCompanion
    case tripSelection
    case reload
    case signOut

    var iconName: String {
        switch self {
        case .addCompanion: "icon-adduser-outline"
        case .tripSelection: "icon-plan-outline"
        case .reload: "icon-reload-outline"
        case .signOut: "rectangle.portrait.and.arrow.right"
        }
    }

    var usesSystemImage: Bool { self == .signOut }

    var accessibilityLabel: String {
        switch self {
        case .addCompanion: "邀请同行人"
        case .tripSelection: "切换旅行"
        case .reload: "重新同步"
        case .signOut: "退出登录"
        }
    }
}

private struct TodayHomeDropdownMenu: View {
    @Binding var isPOIOverlayExpanded: Bool
    let activeAction: TodayQuickAction?
    let isReloading: Bool
    let isAuthenticated: Bool
    let onAction: (TodayQuickAction) -> Void
    let onOverlayExpansionChanged: (Bool) -> Void

    private var isMenuExpanded: Bool { !isPOIOverlayExpanded }
    private var visibleActions: [TodayQuickAction] {
        TodayQuickAction.allCases.filter { $0 != .signOut || isAuthenticated }
    }

    private var expandedHeight: CGFloat {
        48 + 8 + CGFloat(visibleActions.count * 40) + CGFloat(max(0, visibleActions.count - 1) * 12) + 4
    }

    var body: some View {
        VStack(spacing: isMenuExpanded ? 8 : 0) {
            expandButton

            VStack(spacing: 12) {
                ForEach(visibleActions, id: \.self) { action in
                    actionButton(action)
                }
            }
            .padding(.bottom, 4)
            .allowsHitTesting(isMenuExpanded)
            .accessibilityHidden(!isMenuExpanded)
        }
        .frame(width: 48, height: isMenuExpanded ? expandedHeight : 48, alignment: .top)
        // Keep action icons mounted and reveal them with the expanding frame.
        // This couples their movement to the glass drawer instead of fading the
        // entire stack in and out after the drawer animation has begun.
        .clipped()
        .background {
            TodayGlassBackdrop()
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.3), value: isMenuExpanded)
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }

    private var expandButton: some View {
        Button {
            let willExpandOverlay = !isPOIOverlayExpanded
            withAnimation(.snappy(duration: 0.3)) {
                isPOIOverlayExpanded = willExpandOverlay
            }
            onOverlayExpansionChanged(willExpandOverlay)
        } label: {
            Image("icon-dropdown-outline")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(isMenuExpanded ? 180 : 0))
                .frame(width: 40, height: 40)
                .background(
                    isMenuExpanded ? Color.white.opacity(0.32) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 48, height: 48)
        .zIndex(1)
        .accessibilityLabel(isMenuExpanded ? "收起功能菜单并展开地点卡片" : "展开功能菜单并收起地点卡片")
        .accessibilityValue(isMenuExpanded ? "已展开" : "已收起")
    }

    private func actionButton(_ action: TodayQuickAction) -> some View {
        Button {
            guard action != .reload || !isReloading else { return }
            onAction(action)
        } label: {
            Group {
                if action.usesSystemImage {
                    Image(systemName: action.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                } else {
                    Image(action.iconName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                }
            }
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
                    .fill(PrimaryTabPalette.accent)
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

/// Dark custom trip picker used by the home-page dropdown. It replaces the
/// system confirmation dialog with richer trip context and explicit progress.
private struct TodayTripPickerSheet: View {
    let trips: [TripSummary]
    let selectedTripID: Int?
    let tripBeingSelectedID: Int?
    let isStartingNewTrip: Bool
    let onSelect: (TripSummary) -> Void
    let onCreate: () -> Void
    let onDismiss: () -> Void

    private var isBusy: Bool { tripBeingSelectedID != nil || isStartingNewTrip }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 10) {
                    createTripButton

                    if !trips.isEmpty {
                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(.white.opacity(0.12))
                                .frame(height: 1)
                            Text("已有旅行")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .fixedSize()
                            Rectangle()
                                .fill(.white.opacity(0.12))
                                .frame(height: 1)
                        }
                        .padding(.vertical, 4)

                        ForEach(trips) { trip in
                            tripRow(trip)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("切换旅行")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("选择首页要显示的旅行")
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(PrimaryTabPalette.elevatedSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var createTripButton: some View {
        Button(action: onCreate) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.18))
                    if isStartingNewTrip {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("新建一段旅行")
                        .font(.body.weight(.bold))
                    Text("和豆奶 Agent 一起从灵感开始规划")
                        .font(.caption)
                        .opacity(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(
                PrimaryTabPalette.accent,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy && !isStartingNewTrip ? 0.55 : 1)
        .accessibilityHint("唤起豆奶进行新旅行规划，返回时仍保留当前旅行")
    }

    private func tripRow(_ trip: TripSummary) -> some View {
        let isSelected = trip.id == selectedTripID
        let isLoading = trip.id == tripBeingSelectedID

        return Button { onSelect(trip) } label: {
            HStack(spacing: 14) {
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? PrimaryTabPalette.accent : .white.opacity(0.72))
                    .frame(width: 38, height: 38)
                    .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let dateRange = dateRange(for: trip) {
                        Text(dateRange)
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PrimaryTabPalette.accent)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(
                isSelected ? PrimaryTabPalette.accent.opacity(0.12) : PrimaryTabPalette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? PrimaryTabPalette.accent.opacity(0.55) : .white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy && !isLoading ? 0.55 : 1)
        .accessibilityValue(isSelected ? "当前旅行" : "")
    }

    private func dateRange(for trip: TripSummary) -> String? {
        let start = trip.startDate?.replacingOccurrences(of: "-", with: ".")
        let end = trip.endDate?.replacingOccurrences(of: "-", with: ".")
        return switch (start, end) {
        case let (start?, end?): "\(start) — \(end)"
        case let (start?, nil): start
        case let (nil, end?): end
        case (nil, nil): nil
        }
    }
}

struct TodayGlassBackdrop: View {
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
/// deliberately shares the swiper's visibility condition, so the dedicated
/// header toggle expands and collapses both pieces together.
/// Shared date rail used by both the map and itinerary list modes. Keeping one
/// implementation guarantees identical labels, anchoring and drag behavior.
struct TodayDateTimeline: View {
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
    /// A drag settle centers the chosen date immediately. Remember that one
    /// selection so the parent-driven `selectedIndex` update does not launch
    /// a second, overlapping `scrollTo` animation for the same destination.
    @State private var internallyCenteredSelectionIndex: Int?

    private let coordinateSpaceName = "today-date-timeline-viewport"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TravelCompanion",
        category: "TodayTimeline"
    )

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
                Self.logger.debug(
                    "scroll phase=\(String(describing: phase), privacy: .public) selected=\(selectedIndex) anchored=\(anchoredIndex ?? -1)"
                )
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
                if internallyCenteredSelectionIndex == selectedIndex {
                    internallyCenteredSelectionIndex = nil
                    Self.logger.notice(
                        "skip duplicate parent center index=\(selectedIndex)"
                    )
                    return
                }
                internallyCenteredSelectionIndex = nil
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
        // Pin before the scrolling chip reaches the viewport edge. Waiting
        // until it is mostly gone causes the "today" label to be visibly
        // clipped, then appear again as the fixed control.
        let edgeInset: CGFloat = 12
        if todayFrame.minX <= edgeInset { return .leading }
        if todayFrame.maxX >= width - edgeInset { return .trailing }
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
        Self.logger.debug(
            "center date index=\(index) animated=\(animated) immediate=\(settlesImmediately)"
        )
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

        Self.logger.notice(
            "settle date index=\(index) previous=\(selectedIndex) distance=\(abs(closest.frame.midX - anchorX), format: .fixed(precision: 2))"
        )
        anchoredIndex = index
        if index != selectedIndex {
            internallyCenteredSelectionIndex = index
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

private struct TodayTimelineTopInGlobalPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue(), next.isFinite, next > 0 {
            value = next
        }
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
    let expansionProgress: CGFloat
    let onToggleExpanded: () -> Void
    private static let horizontalPadding: CGFloat = 12
    private static let summarySpacing: CGFloat = 4
    private static let verticalPadding: CGFloat = 12
    private static let expandedTopPadding: CGFloat = 12
    private static let expandedBottomPadding: CGFloat = 10
    /// 单行详情行（电话）高度；双行详情行（营业时间、地址）高度。
    /// 高度必须保持确定性，swiper 依赖这些常量计算卡片展开高度。
    private static let detailRowHeight: CGFloat = 54
    private static let detailTallRowHeight: CGFloat = 68
    private static let detailDividerHeight: CGFloat = 1
    private static let detailIconWellSize: CGFloat = 36

    static func height(
        for cardWidth: CGFloat,
        card: TravelCardSnapshot?,
        expansionProgress: CGFloat
    ) -> CGFloat {
        let progress = min(1, max(0, expansionProgress))
        let contentWidth = max(0, cardWidth - horizontalPadding)
        let imageHeight = interpolatedImageHeight(
            contentWidth: contentWidth,
            expansionProgress: progress
        )
        return imageHeight + verticalPadding + detailSectionHeight(for: card) * progress
    }

    private static func interpolatedImageHeight(
        contentWidth: CGFloat,
        expansionProgress: CGFloat
    ) -> CGFloat {
        let collapsedHeight = contentWidth / 2
        let expandedHeight = contentWidth / (16.0 / 9.0)
        return collapsedHeight + (expandedHeight - collapsedHeight) * expansionProgress
    }

    private var normalizedExpansionProgress: CGFloat {
        min(1, max(0, expansionProgress))
    }

    private var imageHeight: CGFloat {
        Self.interpolatedImageHeight(
            contentWidth: max(0, width - Self.horizontalPadding),
            expansionProgress: normalizedExpansionProgress
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverContent
                .frame(maxWidth: .infinity)
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            expandedDetails
                .padding(.horizontal, 8)
                .padding(.top, Self.expandedTopPadding + Self.summarySpacing)
                .padding(.bottom, Self.expandedBottomPadding)
                .frame(
                    height: Self.detailSectionHeight(for: card) * normalizedExpansionProgress,
                    alignment: .top
                )
                .opacity(normalizedExpansionProgress)
                .clipped()
                .allowsHitTesting(normalizedExpansionProgress > 0.99)
                .accessibilityHidden(normalizedExpansionProgress < 0.99)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(
            width: width,
            height: Self.height(
                for: width,
                card: card,
                expansionProgress: normalizedExpansionProgress
            ),
            alignment: .topLeading
        )
        .background {
            ZStack {
                AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.12)
                PrimaryTabPalette.elevatedSurface.opacity(0.72)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        }
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.12),
            radius: 14,
            y: 10
        )
        .accessibilityLabel("第 \(index + 1) 个地点，\(card.title)，\(timeText)")
    }

    private static func detailSectionHeight(for card: TravelCardSnapshot?) -> CGFloat {
        var rowHeights: [CGFloat] = []
        if let businessHours = businessHoursText(for: card), !businessHours.isEmpty {
            rowHeights.append(detailTallRowHeight)
        }
        if let location = locationText(for: card), !location.isEmpty {
            rowHeights.append(detailTallRowHeight)
        }
        if let phone = phoneText(for: card), !phone.isEmpty {
            rowHeights.append(detailRowHeight)
        }
        return expandedTopPadding
            + expandedBottomPadding
            + summarySpacing
            + rowHeights.reduce(0, +)
            + detailDividerHeight * CGFloat(max(0, rowHeights.count - 1))
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

    @ViewBuilder
    private var expandedDetails: some View {
        // 分组列表式详情：图标井 + 标签/值双层级，行间用 palette 分隔线。
        let hasBusinessHours = Self.businessHoursText(for: card) != nil
        let hasLocation = Self.locationText(for: card) != nil
        VStack(alignment: .leading, spacing: 0) {
            if let businessHours = Self.businessHoursText(for: card) {
                // 展开态展示的是 POI 营业时间，不复用收起态的行程到达/离开时间。
                detailInfoRow(
                    iconName: "icon-poi-time-outline",
                    label: "营业时间",
                    value: businessHours,
                    valueLineLimit: 2,
                    rowHeight: Self.detailTallRowHeight
                )
            }

            if let locationText = Self.locationText(for: card) {
                if hasBusinessHours { detailDivider }
                locationDetailRow(locationText)
            }

            if let phoneText = Self.phoneText(for: card) {
                if hasBusinessHours || hasLocation { detailDivider }
                phoneDetailRow(phoneText)
            }

        }
    }

    private var detailDivider: some View {
        PrimaryTabPalette.divider
            .frame(height: Self.detailDividerHeight)
            .padding(.leading, Self.detailIconWellSize + 12)
    }

    /// 详情行左侧的图标井：elevatedSurface 圆角方块承托白色线性图标，
    /// 与账本/旅程页的深色分组行视觉一致。
    private func detailIconWell(_ iconName: String) -> some View {
        Image(iconName)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .frame(width: Self.detailIconWellSize, height: Self.detailIconWellSize)
            .background(
                PrimaryTabPalette.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            }
    }

    private func detailInfoRow(
        iconName: String,
        label: String,
        value: String,
        valueLineLimit: Int,
        rowHeight: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            detailIconWell(iconName)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                Text(value)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(valueLineLimit)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: rowHeight, maxHeight: rowHeight, alignment: .center)
    }

    private func locationDetailRow(_ locationText: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            detailIconWell("icon-poi-location-outline")

            VStack(alignment: .leading, spacing: 3) {
                Text("地址")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                Text(locationText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let compactDistanceText {
                Text(compactDistanceText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(PrimaryTabPalette.accent.opacity(0.9), in: Capsule())
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Self.detailTallRowHeight, maxHeight: Self.detailTallRowHeight, alignment: .center)
    }

    private var distanceInMeters: CLLocationDistance? {
        guard let userLocation,
              let latitude = card.place?.latitude,
              let longitude = card.place?.longitude else {
            return nil
        }
        return CLLocation(
            latitude: userLocation.latitude,
            longitude: userLocation.longitude
        ).distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    private var distanceText: String? {
        guard let distance = distanceInMeters else { return nil }
        return distance >= 1_000
            ? String(format: "距我 %.1f km", distance / 1_000)
            : String(format: "距我 %.0f m", distance)
    }

    /// 地址行尾部胶囊用的紧凑距离文案（省略“距我”前缀）。
    private var compactDistanceText: String? {
        guard let distance = distanceInMeters else { return nil }
        return distance >= 1_000
            ? String(format: "%.1f km", distance / 1_000)
            : String(format: "%.0f m", distance)
    }

    private func phoneDetailRow(_ phoneText: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            detailIconWell("icon-poi-phone-outline")

            VStack(alignment: .leading, spacing: 3) {
                Text("电话")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                Text(phoneText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let phoneURL = Self.phoneURL(for: phoneText) {
                Link(destination: phoneURL) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(PrimaryTabPalette.accent, in: Circle())
                }
                .accessibilityLabel("拨打商家电话")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Self.detailRowHeight, maxHeight: Self.detailRowHeight, alignment: .center)
    }

    private static func phoneURL(for phoneText: String) -> URL? {
        let allowedCharacters = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "+*#,"))
        let dialString = String(phoneText.unicodeScalars.filter(allowedCharacters.contains))
        guard !dialString.isEmpty else { return nil }
        return URL(string: "tel://\(dialString)")
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

    private var coverContent: some View {
        GeometryReader { geometry in
            ZStack {
                // A portrait cover's scaled-to-fill size can be much taller
                // than the collapsed 2:1 card. Constrain it before composing
                // the overlays so the title is laid out against the visible
                // card bounds instead of the image's overflowing bounds.
                coverImage
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                // Matches the product gradient: transparent through 48.37%,
                // reaching 52% black at 79.94% and remaining dark to the bottom.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.4837),
                        .init(color: .black.opacity(0.52), location: 0.7994),
                        .init(color: .black.opacity(0.52), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                // 左上角类型徽章：与 CardDetailView hero 的类型胶囊同一套配色。
                kindBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 10)
                    .padding(.leading, 12)

                // 展开/收起按钮固定在封面右上角（玻璃样式，与地图页头按钮一致），
                // 避免展开态下悬浮遮挡详情行尾部的操作按钮。
                expansionButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 8)
                    .padding(.trailing, 10)

                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)

                    Text("\(index + 1). \(card.title)")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(0)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        metadataItem(
                            iconName: "icon-poi-pin-outline",
                            iconSize: CGSize(width: 11, height: 11),
                            text: timeText
                        )

                        if let distanceText {
                            metadataItem(
                                iconName: "icon-poi-distance-outline",
                                iconSize: CGSize(width: 11, height: 13),
                                text: distanceText
                            )
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .clipped()
        }
    }

    private var kindBadge: some View {
        Label(card.kind.title, systemImage: card.kind.systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(kindTint.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    /// 与 CardDetailView / TodayCardDetailSheet 一致的卡片类型配色。
    private var kindTint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }

    private var expansionButton: some View {
        Button(action: onToggleExpanded) {
            ZStack {
                Image("icon-poi-info-outline")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .opacity(1 - normalizedExpansionProgress)
                    .scaleEffect(1 - 0.2 * normalizedExpansionProgress)
                    .rotationEffect(.degrees(-90 * Double(normalizedExpansionProgress)))

                Image("icon-poi-close-filled")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .opacity(normalizedExpansionProgress)
                    .scaleEffect(0.8 + 0.2 * normalizedExpansionProgress)
                    .rotationEffect(.degrees(90 * Double(1 - normalizedExpansionProgress)))
            }
            .frame(width: 34, height: 34)
            .background { TodayGlassBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(normalizedExpansionProgress > 0.5 ? "收起资讯" : "展开资讯")
    }

    /// 封面底部元数据胶囊：深色半透明底 + 细描边，保证在任何封面图上可读。
    private func metadataItem(iconName: String, iconSize: CGSize, text: String) -> some View {
        HStack(spacing: 5) {
            Image(iconName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize.width, height: iconSize.height)

            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
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
