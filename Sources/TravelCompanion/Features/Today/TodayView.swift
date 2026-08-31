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
    @State private var selectedFlightCard: TravelCardSnapshot?
    @State private var resolvedFlightRoutes: [TodayFlightRoute] = []
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
    @State private var showsSettings = false
    @State private var showsSignIn = false
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
            if agentRunState.isPlanningNewTrip {
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
            } else if syncEngine.hasExplicitlyDeselectedTrip {
                // “暂不选择行程”是稳定的用户选择。后台仍可每五秒刷新
                // 行程列表，但不能用瞬时 `.syncing` 覆盖 Agent 首页。
                agentHome
            } else if syncEngine.trip == nil {
                switch syncEngine.status {
                case .failed(let message):
                    ContentUnavailableView("today.errorLoadSharedTrip", systemImage: "wifi.exclamationmark", description: Text(message))
                case .loading, .syncing:
                    ProgressView("today.openingSharedTrip")
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
        .overlay {
            if let card = selectedFlightCard {
                FlightTicketPopup(
                    card: card,
                    currency: syncEngine.trip?.currency,
                    onDismiss: {
                        withAnimation(.snappy(duration: 0.24)) { selectedFlightCard = nil }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10_000)
            }
        }
        .sheet(item: $detailCard) { card in
            CardDetailView(card: card, currency: syncEngine.trip?.currency)
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
                .presentationBackground(PrimaryTabPalette.background)
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
                syncEngine: syncEngine,
                trips: syncEngine.trips,
                selectedTripID: syncEngine.selectedTripID,
                tripBeingSelectedID: tripBeingSelectedID,
                isStartingNewTrip: isStartingNewTrip,
                onSelect: selectTripFromPicker,
                onCreate: startNewTripFromPicker,
                onDelete: { summary in
                    Task { await syncEngine.deleteTrip(summary) }
                },
                onDismiss: { showsTripPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
            .presentationBackground(PrimaryTabPalette.background)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled(tripBeingSelectedID != nil || isStartingNewTrip)
        }
        .sheet(isPresented: Binding(
            get: { showsSettings },
            set: {
                showsSettings = $0
                if !$0 { clearQuickAction(.settings) }
            }
        )) {
            TodaySettingsSheet(
                appleSignIn: appleSignIn,
                onDismiss: { showsSettings = false }
            )
            // 弹窗外观与「切换旅行」完全一致。
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(28)
            .presentationBackground(PrimaryTabPalette.background)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: Binding(
            get: { showsSignIn },
            set: {
                showsSignIn = $0
                if !$0 { clearQuickAction(.signIn) }
            }
        )) {
            AgentHomeSignInSheet(appleSignIn: appleSignIn)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { linkHandler.browserURL != nil },
            set: { if !$0 { linkHandler.browserURL = nil } }
        )) {
            if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
        }
        .alert("common.cannotOpenLink", isPresented: Binding(
            get: { linkHandler.alertMessage != nil },
            set: { if !$0 { linkHandler.alertMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { linkHandler.alertMessage = nil }
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
        let projectedOccurrences = ItineraryListPresentation.projectedMultiDayCards(
            for: day,
            in: days
        )
        let projectedCards = projectedOccurrences.map(\.card)
        let progressLabels = Dictionary(
            (day.cards.compactMap { card -> (UUID, String)? in
                let progress = ItineraryListPresentation.cardProgress(
                    for: card,
                    on: day,
                    in: days
                )
                guard let label = ItineraryListPresentation.progressLabel(progress) else { return nil }
                return (card.id, label)
            } + projectedOccurrences.compactMap { occurrence -> (UUID, String)? in
                guard let label = ItineraryListPresentation.progressLabel(occurrence.progress) else { return nil }
                return (occurrence.card.id, label)
            }),
            uniquingKeysWith: { first, _ in first }
        )
        let pois = poiCards(in: day, projectedCards: projectedCards)
        let flights = flightCards(in: day, projectedCards: projectedCards)
        let flightIDs = Set(flights.map(\.id))
        let flightRoutes = resolvedFlightRoutes.filter { flightIDs.contains($0.cardID) }
        let points = mapPoints(pois: pois)
        // Adjacent POI pairs that a flight connects are drawn as the flight
        // arc only; their ground route is never requested or rendered.
        let flownLegOriginIDs = ItineraryListPresentation.flownLegOriginIDs(pois: pois, flights: flights)
        let showsPOISwiper = !pois.isEmpty && isPOIOverlayExpanded
        let showsTimeline = pois.isEmpty || isPOIOverlayExpanded
        ZStack(alignment: .top) {
            MapLibreTodayMapCanvas(
                points: points,
                flightRoutes: flightRoutes,
                flownLegOriginIDs: flownLegOriginIDs,
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
                routeRefreshID: 0,
                onFlightSelected: { cardID in
                    guard let card = flights.first(where: { $0.id == cardID }) else { return }
                    selectedFlightCard = card
                }
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
                    flightRoutes: flightRoutes,
                    currentIndex: currentIndex,
                    baseIndex: baseIndex
                )
                Spacer()
                if showsTimeline {
                    let timelineWidth = min(390, max(0, UIScreen.main.bounds.width - 40))
                    VStack(spacing: 8) {
                        // 定位按钮：时间轴上方、页面右下角，点击把地图移到用户位置。
                        HStack {
                            Spacer(minLength: 0)
                            locateButton
                        }

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
                                userLocation: userLocationProvider.coordinate,
                                progressLabels: progressLabels
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
        .task(id: "\(day.id)-\(cardsKey(pois + flights))") {
            hasCenteredOnPOIs = false
            let routes = await AppleMapService.resolveFlightRoutes(cards: flights)
            guard !Task.isCancelled else { return }
            syncEngine.cacheFlightAirportLocations(from: routes)
            resolvedFlightRoutes = routes
            fitAll(pois: pois, flightRoutes: routes)
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
        flightRoutes: [TodayFlightRoute],
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
                    actions: TodayQuickAction.visibleActions(isAuthenticated: appleSignIn.isAuthenticated),
                    onAction: { action in handleQuickAction(action, pois: pois, flightRoutes: flightRoutes) },
                    onOverlayExpansionChanged: { isExpanded in
                        guard isExpanded else { return }
                        fitAll(pois: pois, flightRoutes: flightRoutes)
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
                .accessibilityLabel(Text("today.viewPlanA11y"))
            }
        }
        .padding(.horizontal, 20)
    }

    private func handleQuickAction(
        _ action: TodayQuickAction,
        pois: [TravelCardSnapshot],
        flightRoutes: [TodayFlightRoute]
    ) {
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
            try? RouteCache(modelContext: modelContext).removeAll()
            Task {
                async let retry: Void = syncEngine.retry()
                // Preserve the old drawer's visible full-turn reload animation.
                try? await Task.sleep(for: .seconds(0.75))
                await retry
                fitAll(pois: pois, flightRoutes: flightRoutes)
                isReloading = false
                clearQuickAction(.reload)
            }
        case .settings:
            activeQuickAction = .settings
            showsSettings = true
        case .signIn:
            activeQuickAction = .signIn
            appleSignIn.errorMessage = nil
            showsSignIn = true
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
    /// The planning flag lives on the shared run state so the itinerary list
    /// can enter the same mode by switching back to this section.
    private func startNewTripFromPicker() {
        guard tripBeingSelectedID == nil, !isStartingNewTrip else { return }
        isStartingNewTrip = true
        resetMapSelection()
        agentSessionStore.startNewSession()
        withAnimation(.snappy(duration: 0.32)) {
            agentRunState.beginNewTripPlanning()
            showsTripPicker = false
        }
        isStartingNewTrip = false
    }

    private func cancelNewTripPlanning() {
        agentRunState.clearTransientState()
        agentSessionStore.startNewSession()
        withAnimation(.snappy(duration: 0.32)) {
            agentRunState.endNewTripPlanning()
        }
    }

    private func finishNewTripPlanning() {
        withAnimation(.snappy(duration: 0.32)) {
            agentRunState.endNewTripPlanning()
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
                    Text("common.today")
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
        userLocation: CLLocationCoordinate2D?,
        progressLabels: [UUID: String]
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
                    progressLabel: progressLabels[card.id],
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
        trip.sortedDaysInDateRange
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
        guard let trip = syncEngine.trip, trip.isConfigured else { return String(localized: "common.today") }
        let sorted = sortedDays(in: trip)
        guard !sorted.isEmpty else { return String(localized: "common.today") }
        let baseIndex = baseDayIndex(in: sorted)
        let currentIndex = clampedDayIndex(sorted: sorted, baseIndex: baseIndex)
        guard currentIndex != baseIndex else { return String(localized: "common.today") }
        return dayLabel(for: sorted[currentIndex]) ?? sorted[currentIndex].date
    }

    private func poiCards(
        in day: TripDaySnapshot,
        projectedCards: [TravelCardSnapshot]
    ) -> [TravelCardSnapshot] {
        // 无坐标（缺地址/未定位）的 POI 也保留卡片；地图点位由 mapPoints
        // 逐卡 compactMap 自然跳过，切换到该卡时 focus 因无坐标而不移动地图。
        let persisted = day.cards
            .filter { $0.kind != .flight }
            .sorted { $0.startAt < $1.startAt }
        let projected = projectedCards
            .filter { $0.kind != .flight }
            .sorted { $0.startAt < $1.startAt }
        return persisted + projected
    }

    private func flightCards(
        in day: TripDaySnapshot,
        projectedCards: [TravelCardSnapshot]
    ) -> [TravelCardSnapshot] {
        let persisted = day.cards
            .filter { $0.kind == .flight }
            .sorted { $0.startAt < $1.startAt }
        let projected = projectedCards
            .filter { $0.kind == .flight }
            .sorted { $0.startAt < $1.startAt }
        return persisted + projected
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

    private func cardsKey(_ cards: [TravelCardSnapshot]) -> String {
        cards.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
    }

    private func dayLabel(for day: TripDaySnapshot) -> String? {
        guard let date = Self.dayFormatter.date(from: day.date) else { return day.date }
        return Self.displayFormatter.string(from: date)
    }

    private func timelineLabel(for day: TripDaySnapshot, isToday: Bool) -> String {
        guard let date = Self.dayFormatter.date(from: day.date) else { return day.date }
        guard let weekday = weekdayLabel(from: date), !weekday.isEmpty else { return day.date }
        if isToday { return String(format: String(localized: "common.timelineToday"), weekday) }
        return String(format: String(localized: "common.timelineDate"), Self.timelineNumericFormatter.string(from: date), weekday)
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

    /// 右下角定位按钮（时间轴上方）：把地图显式移到用户当前位置。
    /// 空日期冻结视角后，这是回到用户位置的唯一入口。
    private var locateButton: some View {
        Button {
            guard let location = userLocationProvider.coordinate else { return }
            cameraFocusPointID = nil
            withAnimation(.easeInOut(duration: 0.4)) {
                cameraFocus = location
                cameraRequestID &+= 1
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(PrimaryTabPalette.elevatedSurface, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(
                    color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
                    radius: 12,
                    y: 12
                )
        }
        .buttonStyle(.plain)
        .opacity(userLocationProvider.coordinate == nil ? 0.55 : 1)
        .accessibilityLabel(Text("today.locateA11y"))
    }

    private func fitAll(
        pois: [TravelCardSnapshot],
        flightRoutes: [TodayFlightRoute]
    ) {
        guard !pois.isEmpty || !flightRoutes.isEmpty else { return }
        if pois.count == 1,
           flightRoutes.isEmpty,
           let coordinate = coordinate(of: pois[0]) {
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
        formatter.dateFormat = String(localized: "today.dateFormat.dayTitle")
        return formatter
    }()

    private static let timelineNumericFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = String(localized: "today.dateFormat.timelineNumeric")
        return formatter
    }()

    private static let weekdaySymbols = [
        String(localized: "common.weekday.0"),
        String(localized: "common.weekday.1"),
        String(localized: "common.weekday.2"),
        String(localized: "common.weekday.3"),
        String(localized: "common.weekday.4"),
        String(localized: "common.weekday.5"),
        String(localized: "common.weekday.6")
    ]

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// Shared animated home quick-action drawer. The map couples it to the POI
/// overlay; AgentHome supplies an independent inverse collapsed state.
enum TodayQuickAction: String, CaseIterable {
    case addCompanion
    case tripSelection
    case reload
    case settings
    case signIn

    var iconName: String {
        switch self {
        case .addCompanion: "icon-adduser-outline"
        case .tripSelection: "icon-plan-outline"
        case .reload: "icon-reload-outline"
        case .settings: "gearshape"
        case .signIn: "person.crop.circle"
        }
    }

    var usesSystemImage: Bool { self == .settings || self == .signIn }

    var accessibilityLabel: String {
        switch self {
        case .addCompanion: String(localized: "today.inviteA11y")
        case .tripSelection: String(localized: "today.switchTripA11y")
        case .reload: String(localized: "today.resyncA11y")
        case .settings: String(localized: "today.settingsA11y")
        case .signIn: String(localized: "agent.signInButton")
        }
    }

    /// Sharing requires a signed-in server identity; signed-out users receive
    /// a direct login action in its place. The remaining actions keep working
    /// against the local-first trip store.
    static func visibleActions(isAuthenticated: Bool) -> [TodayQuickAction] {
        allCases.filter { action in
            if action == .addCompanion { return isAuthenticated }
            if action == .signIn { return !isAuthenticated }
            return true
        }
    }

    /// AgentHome represents the state with no active trip. It therefore omits
    /// both trip sharing and the map-specific reload action; signed-out users
    /// additionally receive the direct login action.
    static func agentHomeActions(isAuthenticated: Bool) -> [TodayQuickAction] {
        isAuthenticated
            ? [.tripSelection, .settings]
            : [.tripSelection, .settings, .signIn]
    }
}

struct TodayHomeDropdownMenu: View {
    @Binding var isPOIOverlayExpanded: Bool
    let activeAction: TodayQuickAction?
    let isReloading: Bool
    let actions: [TodayQuickAction]
    let onAction: (TodayQuickAction) -> Void
    let onOverlayExpansionChanged: (Bool) -> Void

    private var isMenuExpanded: Bool { !isPOIOverlayExpanded }

    private var expandedHeight: CGFloat {
        48 + 8 + CGFloat(actions.count * 40) + CGFloat(max(0, actions.count - 1) * 12) + 4
    }

    var body: some View {
        VStack(spacing: isMenuExpanded ? 8 : 0) {
            expandButton

            VStack(spacing: 12) {
                ForEach(actions, id: \.self) { action in
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
        .accessibilityLabel(Text(isMenuExpanded ? "today.collapseA11y" : "today.expandA11y"))
        .accessibilityValue(Text(isMenuExpanded ? "today.expandedValue" : "today.collapsedValue"))
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
/// 主页左上角「设置」的半屏弹窗：与「共享旅程」「切换旅行」同一套设计
/// 语言（头部标题 + 关闭按钮、深色卡片行），提供语言、隐私政策与退出登录。
struct TodaySettingsSheet: View {
    @ObservedObject var appleSignIn: AppleSignInStore
    let onDismiss: () -> Void

    /// 语言偏好：同步写入系统 AppleLanguages，重启 App 后生效。
    @AppStorage("preferredAppLanguage") private var preferredLanguage = "system"
    @State private var isLanguageExpanded = false
    @State private var showsPrivacyPolicy = false
    @State private var showsSignIn = false
    @State private var showsSignOutConfirmation = false
    @State private var signOutErrorMessage: String?

    private struct LanguageOption {
        let code: String
        let name: String
    }

    private var languageOptions: [LanguageOption] {
        [
            LanguageOption(code: "system", name: String(localized: "settings.languageSystem")),
            LanguageOption(code: "zh-Hans", name: String(localized: "settings.languageZH")),
            LanguageOption(code: "zh-Hant-TW", name: String(localized: "settings.languageZHTW")),
            LanguageOption(code: "zh-Hant-HK", name: String(localized: "settings.languageZHHK")),
            LanguageOption(code: "en", name: String(localized: "settings.languageEN"))
        ]
    }

    private var currentLanguageName: String {
        languageOptions.first { $0.code == preferredLanguage }?.name ?? String(localized: "settings.languageSystem")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 10) {
                    languageRow

                    if isLanguageExpanded {
                        languageOptionList
                    }

                    privacyRow

                    if appleSignIn.isAuthenticated {
                        signOutRow
                    } else {
                        signInRow
                    }

                    versionFooter
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
        .sheet(isPresented: $showsPrivacyPolicy) {
            TodayPrivacyPolicySheet(onDismiss: { showsPrivacyPolicy = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(PrimaryTabPalette.background)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showsSignIn) {
            AgentHomeSignInSheet(appleSignIn: appleSignIn)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .alert("settings.signOutConfirmTitle", isPresented: $showsSignOutConfirmation) {
            Button("settings.signOutConfirmButton", role: .destructive) {
                if appleSignIn.signOut() {
                    onDismiss()
                } else {
                    signOutErrorMessage = appleSignIn.errorMessage ?? String(localized: "settings.signOutFailedRetry")
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.signOutMessage")
        }
        .alert("settings.signOutFailedTitle", isPresented: Binding(
            get: { signOutErrorMessage != nil },
            set: { if !$0 { signOutErrorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { signOutErrorMessage = nil }
        } message: {
            Text(signOutErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("settings.title")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("settings.subtitle")
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
            .accessibilityLabel(Text("common.close"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var languageRow: some View {
        rowCard(icon: "globe", title: String(localized: "settings.language"), detail: currentLanguageName) {
            withAnimation(.snappy(duration: 0.25)) {
                isLanguageExpanded.toggle()
            }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .rotationEffect(.degrees(isLanguageExpanded ? 90 : 0))
        }
    }

    private var languageOptionList: some View {
        VStack(spacing: 10) {
            ForEach(languageOptions, id: \.code) { option in
                languageOptionRow(option)
            }

            Text("settings.languageNote")
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func languageOptionRow(_ option: LanguageOption) -> some View {
        let isSelected = preferredLanguage == option.code

        return Button {
            applyLanguage(option.code)
            withAnimation(.snappy(duration: 0.25)) {
                isLanguageExpanded = false
            }
        } label: {
            HStack(spacing: 12) {
                Text(option.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 记录偏好并写入系统 AppleLanguages（跟随系统 = 移除覆盖），重启后生效。
    private func applyLanguage(_ code: String) {
        preferredLanguage = code
        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    private var privacyRow: some View {
        rowCard(icon: "hand.raised", title: String(localized: "settings.privacy")) {
            showsPrivacyPolicy = true
        } trailing: {
            chevron
        }
    }

    private var signOutRow: some View {
        rowCard(
            icon: "rectangle.portrait.and.arrow.right",
            iconTint: .red,
            title: String(localized: "settings.signOut"),
            titleColor: .red
        ) {
            showsSignOutConfirmation = true
        } trailing: {
            chevron
        }
    }

    private var signInRow: some View {
        rowCard(
            icon: "person.crop.circle.badge.checkmark",
            iconTint: PrimaryTabPalette.accent,
            title: String(localized: "agent.signInButton"),
            titleColor: PrimaryTabPalette.accent
        ) {
            appleSignIn.errorMessage = nil
            showsSignIn = true
        } trailing: {
            chevron
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(PrimaryTabPalette.secondaryText)
    }

    private var versionFooter: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"

        return Text(String(format: String(localized: "settings.version"), version, build))
            .font(.caption)
            .foregroundStyle(PrimaryTabPalette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    /// 与行程行同款的设置行卡片：左侧图标贴片 + 标题/副标题 + 自定义尾部。
    private func rowCard<Trailing: View>(
        icon: String,
        iconTint: Color = .white.opacity(0.72),
        title: String,
        titleColor: Color = .white,
        detail: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 38, height: 38)
                    .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(titleColor)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 「隐私政策」内嵌页：内容依据 App 隐私清单（PrivacyInfo.xcprivacy）与
/// 实际代码行为撰写，不依赖外部链接。
private struct TodayPrivacyPolicySheet: View {
    let onDismiss: () -> Void

    private struct PolicySection: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private let sections: [PolicySection] = [
        PolicySection(id: "no-tracking", title: "settings.noTrackingTitle", body: "settings.noTrackingBody"),
        PolicySection(id: "sign-in", title: "settings.signInTitle", body: "settings.signInBody"),
        PolicySection(id: "shared-data", title: "settings.sharedDataTitle", body: "settings.sharedDataBody"),
        PolicySection(id: "photo", title: "settings.photoTitle", body: "settings.photoBody"),
        PolicySection(id: "local-first", title: "settings.localFirstTitle", body: "settings.localFirstBody")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                            Text(section.body)
                                .font(.subheadline)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
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
                Text("settings.privacySheetTitle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("settings.privacySheetSubtitle")
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
            .accessibilityLabel(Text("common.close"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }
}

/// 「切换旅行」弹窗：主页左上角菜单与 Agent 工作台共用同一实现。
/// 行程区使用原生 List + swipeActions 提供左滑编辑/删除（仅 owner 可操作）；
/// 编辑统一弹出「旅行与偏好」（AgentContextSheet，保存由弹窗自己提交）。
struct TodayTripPickerSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    let trips: [TripSummary]
    let selectedTripID: Int?
    let tripBeingSelectedID: Int?
    let isStartingNewTrip: Bool
    /// 弹窗副标题：主页默认「选择首页要显示的旅行」，工作台传 Agent 语境文案。
    var subtitle: String = String(localized: "tripswitch.subtitle")
    let onSelect: (TripSummary) -> Void
    let onCreate: () -> Void
    let onDelete: (TripSummary) -> Void
    let onDismiss: () -> Void

    /// 「旅行与偏好」编辑弹窗需要保存 Agent 偏好；sheet 内容继承宿主环境。
    @EnvironmentObject private var agentSessionStore: AgentV2SessionStore
    @State private var editingTrip: TripSummary?
    @State private var tripPendingDeletion: TripSummary?

    private var isBusy: Bool { tripBeingSelectedID != nil || isStartingNewTrip }

    var body: some View {
        VStack(spacing: 0) {
            header

            // 原生 List + swipeActions 提供左滑编辑/删除；行背景与分隔线
            // 全部隐藏，保持自定义卡片外观。
            List {
                Group {
                    createTripButton

                    if !trips.isEmpty {
                        existingTripsDivider
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))

                ForEach(trips) { trip in
                    tripRowContent(trip)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if trip.role == "owner" {
                                Button(role: .destructive) {
                                    tripPendingDeletion = trip
                                } label: {
                                    Label("tripswitch.deleteA11y", systemImage: "trash")
                                }
                            }

                            Button {
                                editingTrip = trip
                            } label: {
                                Label("tripswitch.editA11y", systemImage: "pencil")
                            }
                            .tint(PrimaryTabPalette.accent)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 20, for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal)
        .sheet(item: $editingTrip) { summary in
            // 左滑编辑改用「旅行与偏好」弹窗（与 Agent 首页同一实现），
            // 保存由弹窗自己在关闭时提交。
            AgentContextSheet(syncEngine: syncEngine, store: agentSessionStore, targetSummary: summary)
                .presentationDetents([.fraction(0.8)])
        }
        .alert(
            "tripswitch.deleteTitle",
            isPresented: Binding(
                get: { tripPendingDeletion != nil },
                set: { if !$0 { tripPendingDeletion = nil } }
            ),
            presenting: tripPendingDeletion
        ) { summary in
            Button("common.cancel", role: .cancel) {
                tripPendingDeletion = nil
            }
            Button("common.delete", role: .destructive) {
                tripPendingDeletion = nil
                onDelete(summary)
            }
        } message: { summary in
            Text(String(format: String(localized: "tripswitch.deleteMessage"), summary.displayName))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("tripswitch.title")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
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
            .accessibilityLabel(Text("common.close"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var existingTripsDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
            Text("tripswitch.existing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .fixedSize()
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
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
                    Text("tripswitch.newTripButton")
                        .font(.body.weight(.bold))
                    Text("tripswitch.newTripSubtitle")
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
        .accessibilityHint(Text("tripswitch.newTripHint"))
    }

    /// 行程行卡片：List 行内的内容视图，左滑编辑/删除由原生 swipeActions 提供。
    private func tripRowContent(_ trip: TripSummary) -> some View {
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
        .accessibilityValue(isSelected ? Text("tripswitch.currentValue") : Text(verbatim: ""))
    }

    private func dateRange(for trip: TripSummary) -> String? {
        let start = trip.startDate?.replacingOccurrences(of: "-", with: ".")
        let end = trip.endDate?.replacingOccurrences(of: "-", with: ".")
        return switch (start, end) {
        case let (start?, end?): String(format: String(localized: "tripswitch.dateRange"), start, end)
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
        .accessibilityLabel(Text("today.backToTodayA11y"))
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

/// Compact ticket surfaced by tapping the flight arc or its aircraft marker.
/// It intentionally contains no itinerary edit affordances: the map interaction
/// is for orientation first, with the existing detail sheet one tap away.
private struct TodayMapFlightCard: View {
    let card: TravelCardSnapshot
    let currency: String?
    let onShowDetails: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Label(card.kind.title, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                Spacer()
                Text(Self.dateFormatter.string(from: card.startAt))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 11) {
                        AirlineLogoBadge(logoURL: airlineLogoURL, size: 38, cornerRadius: 11)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AgentFlightDisplay.routeTitle(
                                from: card.fromAirport,
                                to: card.toAirport,
                                fallback: card.title
                            ))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            Text(flightNumber)
                                .font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        Spacer(minLength: 8)
                        if let price {
                            Text(price)
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        airport(card.fromAirport, time: Self.timeFormatter.string(from: card.startAt), alignment: .leading)
                        VStack(spacing: 7) {
                            Image(systemName: "airplane")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                            HStack(spacing: 4) {
                                Circle().fill(.white.opacity(0.26)).frame(width: 4, height: 4)
                                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                                Circle().fill(.white.opacity(0.26)).frame(width: 4, height: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        airport(
                            card.toAirport,
                            time: card.endAt.map { Self.timeFormatter.string(from: $0) }
                                ?? String(localized: "agent.timePending"),
                            alignment: .trailing
                        )
                    }
                }
                .padding(16)

                ticketDivider

                Button(action: onShowDetails) {
                    HStack {
                        Text("travelcard.viewDetails")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background {
                LinearGradient(
                    colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private func airport(
        _ value: String?,
        time: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(AgentFlightDisplay.airportCode(value))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(nonEmpty(value) ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(time)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var ticketDivider: some View {
        HStack(spacing: 5) {
            ForEach(0..<20, id: \.self) { _ in
                Capsule().fill(.white.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: -9)
        }
        .overlay(alignment: .trailing) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: 9)
        }
    }

    private var airlineLogoURL: URL? {
        if let url = CardImageURL.resolve(card.airlineLogoURL) { return url }
        let code = card.airlineCode ?? AgentFlightDisplay.airlineCode(fromBookingCode: card.bookingCode)
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }

    private var flightNumber: String {
        nonEmpty(card.bookingCode)
            ?? nonEmpty(card.airlineCode)
            ?? String(localized: "agent.flightNumberPending")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var price: String? {
        CardPrice.format(minor: card.actualPriceMinor ?? card.priceMinor, currency: currency)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct POICard: View {
    let card: TravelCardSnapshot
    let index: Int
    let width: CGFloat
    let userLocation: CLLocationCoordinate2D?
    let expansionProgress: CGFloat
    let progressLabel: String?
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
        .accessibilityLabel(Text(String(format: String(localized: "today.poiA11y"), index + 1, card.title, timeText)))
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
                    label: String(localized: "today.hoursLabel"),
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
                Text("today.addressLabel")
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
            ? String(format: String(localized: "today.distanceFromMeKm"), distance / 1_000)
            : String(format: String(localized: "today.distanceFromMeMeters"), Int(distance.rounded()))
    }

    /// 地址行尾部胶囊用的紧凑距离文案（省略“距我”前缀）。
    private var compactDistanceText: String? {
        guard let distance = distanceInMeters else { return nil }
        return distance >= 1_000
            ? String(format: String(localized: "common.distanceKm"), distance / 1_000)
            : String(format: String(localized: "common.distanceMeters"), Int(distance.rounded()))
    }

    private func phoneDetailRow(_ phoneText: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            detailIconWell("icon-poi-phone-outline")

            VStack(alignment: .leading, spacing: 3) {
                Text("today.phoneLabel")
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
                .accessibilityLabel(Text("today.callA11y"))
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
                HStack(spacing: 7) {
                    kindBadge
                    if let progressLabel {
                        Text(progressLabel)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.48), in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                    }
                }
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

                    Text(String(format: String(localized: "today.cardCoverTitle"), index + 1, card.title))
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

    /// 与统一的 CardDetailView 一致的卡片类型配色。
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
        .accessibilityLabel(normalizedExpansionProgress > 0.5 ? Text("today.collapseInfoA11y") : Text("today.expandInfoA11y"))
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
