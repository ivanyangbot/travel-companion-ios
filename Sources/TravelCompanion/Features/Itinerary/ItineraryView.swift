import AuthenticationServices
import MapKit
import SwiftData
import SwiftUI
import UIKit

struct ItineraryView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var sharedLinkStore: PendingSharedLinkStore
    @ObservedObject var appleSignIn: AppleSignInStore
    @Binding var section: JourneyView.Section
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var agentSessionStore: AgentV2SessionStore
    @EnvironmentObject private var agentRunState: AgentV2RunState
    @State private var activeDaySheet: DaySheet?
    @State private var editingTrip: TripSummary?
    @State private var showsSignOutConfirmation = false
    @State private var agentSheet: ItineraryAgentSheet?
    @State private var dayPendingDeletion: TripDaySnapshot?
    @State private var activeCardEditor: CardEditorTarget?
    @State private var detailCard: TravelCardSnapshot?
    @State private var flightDetailCard: TravelCardSnapshot?
    @State private var cardPendingDeletion: TravelCardSnapshot?
    @State private var expenseEditorDate: Date?
    @State private var showsSharingSheet = false
    @State private var isHeaderMenuExpanded = true
    @State private var headerQuickAction: TodayQuickAction?
    @State private var isReloading = false
    @State private var showsTripPicker = false
    @State private var tripBeingSelectedID: Int?
    @State private var showsSettings = false
    @State private var showsSignIn = false
    @State private var inviteBeingJoined: String?
    @State private var signOutErrorMessage: String?
    @State private var selectedListDate: String?
    @State private var programmaticScrollTarget: UUID?
    @State private var visibleCardOrderByDay: [UUID: [UUID]] = [:]
    @State private var revealedListCardID: UUID?
    @State private var listCardSwipeGestureCardID: UUID?
    @State private var listCardSwipeTranslation: CGFloat = 0
    @State private var longPressedListCardID: UUID?
    @State private var suppressedListCardTapID: UUID?
    @State private var suppressedListCardTapReleaseTask: Task<Void, Never>?
    @State private var settlingListCard: ItinerarySettlingCard?
    @State private var settlingListCardCenter: CGPoint = .zero
    @State private var settlingListCardIsAnimating = false
    @State private var settlingListCardTask: Task<Void, Never>?
    @State private var draggedListCard: ItineraryDraggedCard?
    @State private var draggedListCardTranslation: CGSize = .zero
    @State private var draggedListCardStartFrame: CGRect?
    @State private var draggedListCardDestinationDayID: UUID?
    @State private var draggedListCardDestinationIndex: Int?
    @State private var draggedListCardBaseFrames: [UUID: CGRect] = [:]
    @State private var draggedListCardBaseDayFrames: [UUID: CGRect] = [:]
    @State private var itineraryScrollViewportFrame: CGRect = .zero
    @State private var itineraryScrollOffsetY: CGFloat = 0
    @State private var itineraryScrollContentHeight: CGFloat = 0
    @State private var itineraryScrollViewportHeight: CGFloat = 0
    @State private var draggedListCardStartScrollOffsetY: CGFloat = 0
    @State private var draggedListCardFingerY: CGFloat?
    @State private var dragAutoScrollVelocity: CGFloat = 0
    @State private var dragAutoScrollTask: Task<Void, Never>?
    @State private var itineraryScrollPosition = ScrollPosition()
    @State private var itineraryNow = Date.now
    @State private var routeRefreshRevision = 0
    @State private var itineraryResolvedCityByDate: [String: String] = [:]
    /// 左侧时间线轨道列（类别 icon + 起止当地时间），设置页可关；关闭后
    /// 卡片恢复满宽、卡内恢复类别文案/icon。默认开启。
    @AppStorage("itinerary.showsCardRail") private var showsCardRail = true
    /// 相邻卡的交通耗时（秒），由各段 CardLegEstimateView 异步上报；
    /// 轨道底部时间据此显示「最晚出发时刻」。
    @State private var itineraryTransitSecondsByCardID: [UUID: Int] = [:]
    /// Members of the selected shared trip (signed-in only); >1 means the
    /// trip has companions and flight cards may reveal ticket passengers.
    @State private var sharedMemberCount = 0
    @StateObject private var itineraryListScrollController = ItineraryListScrollController()
    @StateObject private var itineraryListGeometryCache = ItineraryListGeometryCache()
    @StateObject private var linkHandler = ExternalLinkHandler()

    /// Geometry preferences move every frame while the user scrolls. Keeping
    /// them in a non-publishing reference cache prevents those measurements
    /// from invalidating and rebuilding the entire list on every frame.
    private var itineraryCardFrames: [UUID: CGRect] { itineraryListGeometryCache.cardFrames }
    private var itineraryDayFrames: [UUID: CGRect] { itineraryListGeometryCache.dayFrames }

    private var deleteDayAlertPresented: Binding<Bool> {
        optionalItemPresented($dayPendingDeletion)
    }

    private var signOutErrorAlertPresented: Binding<Bool> {
        optionalItemPresented($signOutErrorMessage)
    }

    private var deleteCardAlertPresented: Binding<Bool> {
        optionalItemPresented($cardPendingDeletion)
    }

    private var cannotOpenLinkAlertPresented: Binding<Bool> {
        Binding(get: { linkHandler.alertMessage != nil }) { isPresented in
            if !isPresented { linkHandler.alertMessage = nil }
        }
    }

    private var sharingSheetPresented: Binding<Bool> {
        Binding(get: { showsSharingSheet }) { isPresented in
            showsSharingSheet = isPresented
            if !isPresented { clearHeaderQuickAction(.addCompanion) }
        }
    }

    private var tripPickerPresented: Binding<Bool> {
        Binding(get: { showsTripPicker }) { isPresented in
            showsTripPicker = isPresented
            if !isPresented {
                clearHeaderQuickAction(.tripSelection)
                withAnimation(.snappy(duration: 0.28)) {
                    isHeaderMenuExpanded = true
                }
            }
        }
    }

    private var settingsSheetPresented: Binding<Bool> {
        Binding(get: { showsSettings }) { isPresented in
            showsSettings = isPresented
            if !isPresented { clearHeaderQuickAction(.settings) }
        }
    }

    private var signInSheetPresented: Binding<Bool> {
        Binding(get: { showsSignIn }) { isPresented in
            showsSignIn = isPresented
            if !isPresented { clearHeaderQuickAction(.signIn) }
        }
    }

    private var expenseEditorPresented: Binding<Bool> {
        optionalItemPresented($expenseEditorDate)
    }

    private var browserPresented: Binding<Bool> {
        Binding(get: { linkHandler.browserURL != nil }) { isPresented in
            if !isPresented { linkHandler.browserURL = nil }
        }
    }

    private func optionalItemPresented<Value>(_ item: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }) { isPresented in
            if !isPresented { item.wrappedValue = nil }
        }
    }

    var body: some View {
        NavigationStack {
            alertContent
            .alert("itinerary.deleteDayTitle", isPresented: deleteDayAlertPresented, presenting: dayPendingDeletion) { day in
                Button("common.delete", role: .destructive) {
                    Task { await syncEngine.deleteDay(day) }
                    dayPendingDeletion = nil
                }
                Button("common.cancel", role: .cancel) { dayPendingDeletion = nil }
            } message: { _ in
                Text("itinerary.deleteDayMessage")
            }
            .alert("settings.signOutConfirmTitle", isPresented: $showsSignOutConfirmation) {
                Button("settings.signOutConfirmButton", role: .destructive) {
                    if !appleSignIn.signOut() {
                        signOutErrorMessage = appleSignIn.errorMessage ?? String(localized: "settings.signOutFailedRetry")
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("settings.signOutMessage")
            }
            .alert("settings.signOutFailedTitle", isPresented: signOutErrorAlertPresented) {
                Button("common.ok", role: .cancel) { signOutErrorMessage = nil }
            } message: {
                Text(signOutErrorMessage ?? "")
            }
            .alert("itinerary.deleteCardTitle", isPresented: deleteCardAlertPresented, presenting: cardPendingDeletion) { card in
                Button("common.delete", role: .destructive) {
                    Task { await syncEngine.deleteCard(card) }
                    cardPendingDeletion = nil
                }
                Button("common.cancel", role: .cancel) { cardPendingDeletion = nil }
            } message: { _ in
                Text("itinerary.deleteCardMessage")
            }
            .alert("common.cannotOpenLink", isPresented: cannotOpenLinkAlertPresented) {
                Button("common.ok", role: .cancel) { linkHandler.alertMessage = nil }
            } message: {
                Text(linkHandler.alertMessage ?? "")
            }
            .onChange(of: sharedLinkStore.pendingInviteToken) { _, token in
                guard token != nil else { return }
                joinPendingInviteIfPossible()
            }
            .sheet(isPresented: sharingSheetPresented) {
                TripSharingSheet(syncEngine: syncEngine)
            }
            .sheet(isPresented: tripPickerPresented) {
                TodayTripPickerSheet(
                    syncEngine: syncEngine,
                    trips: syncEngine.trips,
                    selectedTripID: syncEngine.selectedTripID,
                    tripBeingSelectedID: tripBeingSelectedID,
                    isStartingNewTrip: false,
                    onSelect: selectTripFromPicker,
                    onCreate: {
                        showsTripPicker = false
                        startNewTripPlanning()
                    },
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
                .interactiveDismissDisabled(tripBeingSelectedID != nil)
            }
            .sheet(isPresented: settingsSheetPresented) {
                TodaySettingsSheet(
                    appleSignIn: appleSignIn,
                    onDismiss: { showsSettings = false }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(PrimaryTabPalette.background)
                .presentationContentInteraction(.scrolls)
            }
            .sheet(isPresented: signInSheetPresented) {
                AgentHomeSignInSheet(appleSignIn: appleSignIn)
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
            .task {
                joinPendingInviteIfPossible()
            }
            .task(id: "\(syncEngine.selectedTripID)-\(syncEngine.isUserAuthenticated)") {
                guard syncEngine.isUserAuthenticated, syncEngine.selectedTripID != nil else {
                    sharedMemberCount = 0
                    return
                }
                sharedMemberCount = (try? await syncEngine.fetchTripMembers())?.count ?? 0
            }
            .onChange(of: syncEngine.isUserAuthenticated) { _, isAuthenticated in
                guard isAuthenticated else { return }
                joinPendingInviteIfPossible()
            }
        }
        .overlay {
            if let card = flightDetailCard {
                FlightTicketPopup(
                    card: card,
                    currency: syncEngine.trip?.currency,
                    showsPassengers: syncEngine.isUserAuthenticated && sharedMemberCount > 1,
                    onDismiss: {
                        withAnimation(.snappy(duration: 0.24)) { flightDetailCard = nil }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10_000)
            }
        }
    }

    private var alertContent: some View {
        itineraryContent
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { syncStatus }
            .sheet(item: $activeDaySheet) { sheet in
                let editingDay = sheet.day
                DayEditor(existingDay: editingDay, existingDates: Set(syncEngine.trip?.days.map(\.date) ?? [])) { date in
                    Task {
                        if let editingDay {
                            await syncEngine.updateDay(editingDay, date: date)
                        } else {
                            await syncEngine.addDay(date)
                        }
                    }
                }
            }
            .sheet(item: $editingTrip) { summary in
                // 编辑指定行程统一走「旅行与偏好」弹窗，与首页 Agent 的
                // 语境弹窗同一实现；保存由弹窗自己在关闭时提交。
                AgentContextSheet(syncEngine: syncEngine, store: agentSessionStore, targetSummary: summary)
                    .presentationDetents([.fraction(0.8)])
            }
            .sheet(item: $agentSheet) { sheet in
                AgentWorkbenchView(
                    syncEngine: syncEngine,
                    appleSignIn: appleSignIn,
                    initialMessage: sheet.initialMessage
                )
                .presentationDetents([.fraction(0.8), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .presentationBackground(PrimaryTabPalette.background)
            }
            .sheet(item: $detailCard) { card in
                CardDetailView(card: card, currency: syncEngine.trip?.currency, showsPassengers: syncEngine.isUserAuthenticated && sharedMemberCount > 1)
                    .presentationDetents([.fraction(0.82), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(30)
                    .presentationBackground(PrimaryTabPalette.background)
            }
            .sheet(item: $activeCardEditor) { target in
                CardEditorView(
                    day: target.day,
                    existingCard: target.card,
                    currency: syncEngine.trip?.currency,
                    initialURL: target.initialURL,
                    onImportLink: { url in try await syncEngine.importCardFromLink(url: url) }
                ) { request in
                    Task {
                        if let card = target.card {
                            await syncEngine.updateCard(card, request: request)
                        } else {
                            await syncEngine.addCard(to: target.day, request: request)
                        }
                    }
                }
            }
            .sheet(isPresented: expenseEditorPresented) {
                if let trip = syncEngine.trip, let date = expenseEditorDate {
                    ExpenseEditorView(trip: trip, initialDate: date) { request in
                        Task { await syncEngine.addExpense(request) }
                    }
                }
            }
            .sheet(isPresented: browserPresented) {
                if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
            }
    }

    @ViewBuilder
    private var itineraryContent: some View {
        if let trip = syncEngine.trip {
            if trip.isConfigured {
                detailedItinerary(trip)
            } else {
                // 行程存在但未完成设置：与首页地图模式一致，交给 Agent 首页
                // 引导规划，不再展示本地设置表单。
                agentHomeGuide
            }
        } else if case .failed(let message) = syncEngine.status {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "today.errorLoadSharedTrip",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
                Button("common.retry") { Task { await syncEngine.retry() } }
            }
        } else if case .synced = syncEngine.status {
            agentHomeGuide
        } else if case .localOnly = syncEngine.status {
            agentHomeGuide
        } else {
            ProgressView("today.openingSharedTrip")
        }
    }

    /// 无行程/未设置状态下的 Agent 首页引导，对齐首页地图模式的空态分支。
    private var agentHomeGuide: some View {
        AgentHomeView(syncEngine: syncEngine, appleSignIn: appleSignIn)
    }

    private func detailedItinerary(_ trip: SharedTripSnapshot) -> some View {
        let days = trip.sortedDaysInDateRange
        let todayIndex = ItineraryListPresentation.todayIndex(in: days)
        let selectedIndex = ItineraryListPresentation.selectedIndex(
            date: selectedListDate,
            in: days
        )

        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    itineraryPinnedHeader(
                        trip: trip,
                        days: days,
                        selectedIndex: selectedIndex,
                        todayIndex: todayIndex,
                        timelineWidth: min(390, max(0, geometry.size.width - 40))
                    )

                    if days.isEmpty {
                        ContentUnavailableView {
                            Label("itinerary.noDatesTitle", systemImage: "calendar.badge.plus")
                        } description: {
                            Text("itinerary.noDatesDesc")
                        } actions: {
                            Button("itinerary.addDateButton") { activeDaySheet = .add }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        itineraryDayScroller(trip: trip, days: days)
                    }
                }

                draggedItineraryCardOverlay(days: days)
            }
            .coordinateSpace(name: "itinerary-list-root")
            .gesture(
                ItineraryLongPressDragGesture(
                    isEnabled: listCardSwipeGestureCardID == nil && revealedListCardID == nil,
                    canBegin: { location in
                        listCardDragTarget(at: location, days: days) != nil
                    },
                    onBegan: { location in
                        handleRootListCardLongPressBegan(at: location, days: days)
                    },
                    onChanged: { translation in
                        handleRootListCardLongPressChanged(translation, days: days)
                    },
                    onEnded: { translation in
                        handleRootListCardLongPressEnded(translation, days: days)
                    },
                    onCancelled: {
                        cancelActiveListCardLongPress()
                    }
                )
            )
            .background(Color.black)
            .onAppear {
                if selectedListDate == nil {
                    selectedListDate = days.first?.date
                }
            }
            .onChange(of: days.map(\.date)) { _, dates in
                guard let selectedListDate, dates.contains(selectedListDate) else {
                    self.selectedListDate = dates.first
                    return
                }
            }
            .onDisappear {
                stopDragAutoScroll()
                settlingListCardTask?.cancel()
                suppressedListCardTapReleaseTask?.cancel()
            }
            .task {
                // "Current or next card" highlighting only needs minute
                // granularity; assigning an unrounded date here invalidated
                // the whole list on every 30 s tick.
                while !Task.isCancelled {
                    let now = Date.now
                    let minute = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: now
                    )
                    itineraryNow = Calendar.current.date(from: minute) ?? now
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        break
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func draggedItineraryCardOverlay(days: [TripDaySnapshot]) -> some View {
        let timeZoneByCardID = ItineraryLocalTime.timeZoneByCardID(in: days)
        if let draggedListCard,
           let day = days.first(where: { $0.id == draggedListCard.dayID }),
           let card = day.cards.first(where: { $0.id == draggedListCard.cardID }),
           let startFrame = draggedListCardStartFrame {
            let index = orderedListCards(for: day).firstIndex(where: { $0.id == card.id }) ?? 0
            itineraryCompactCardContent(
                card,
                index: index,
                showsTimeAccent: isCurrentOrNext(card, in: days),
                timeZone: timeZoneByCardID[card.id] ?? ItineraryLocalTime.deviceTimeZone
            )
                .frame(width: startFrame.width, height: startFrame.height)
                .scaleEffect(1.025)
                .position(
                    x: startFrame.midX + draggedListCardTranslation.width,
                    y: startFrame.midY + draggedListCardTranslation.height
                )
                .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(100_000)
        }

        if let settlingListCard {
            itineraryCompactCardContent(
                settlingListCard.card,
                index: settlingListCard.destinationIndex,
                showsTimeAccent: isCurrentOrNext(settlingListCard.card, in: days),
                timeZone: timeZoneByCardID[settlingListCard.card.id] ?? ItineraryLocalTime.deviceTimeZone
            )
            .frame(width: settlingListCard.startFrame.width, height: settlingListCard.startFrame.height)
            .scaleEffect(settlingListCardIsAnimating ? 1 : 1.025)
            .position(settlingListCardCenter)
            .shadow(
                color: .black.opacity(settlingListCardIsAnimating ? 0.18 : 0.5),
                radius: settlingListCardIsAnimating ? 8 : 22,
                y: settlingListCardIsAnimating ? 3 : 12
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(100_000)
        }
    }

    private func itineraryPinnedHeader(
        trip: SharedTripSnapshot,
        days: [TripDaySnapshot],
        selectedIndex: Int,
        todayIndex: Int,
        timelineWidth: CGFloat
    ) -> some View {
        VStack(spacing: 9) {
            ZStack(alignment: .top) {
                Text(
                    days.indices.contains(selectedIndex)
                        ? ItineraryListPresentation.timelineLabel(
                            days[selectedIndex],
                            selectedIndex == todayIndex
                        )
                        : ""
                )
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 48)

                HStack(alignment: .top, spacing: 0) {
                    TodayHomeDropdownMenu(
                        isPOIOverlayExpanded: $isHeaderMenuExpanded,
                        activeAction: headerQuickAction,
                        isReloading: isReloading,
                        actions: TodayQuickAction.visibleActions(isAuthenticated: appleSignIn.isAuthenticated),
                        onAction: { action in handleHeaderQuickAction(action) },
                        onOverlayExpansionChanged: { _ in }
                    )

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.28)) { section = .today }
                    } label: {
                        Image("icon-mapview-outline")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                        .frame(width: 40, height: 40)
                    }
                    .itineraryHeaderButtonStyle()
                    .accessibilityLabel(Text("itinerary.mapModeA11y"))
                }
            }
            .zIndex(1)
            .frame(height: 48, alignment: .top)
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Text(trip.destination?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "common.unnamedTrip"))
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button { editSelectedTrip() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("itinerary.editTripA11y"))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            if !days.isEmpty {
                TodayDateTimeline(
                    days: days,
                    selectedIndex: selectedIndex,
                    todayIndex: todayIndex,
                    width: timelineWidth,
                    label: ItineraryListPresentation.timelineLabel
                ) { index in
                    guard days.indices.contains(index) else { return }
                    selectedListDate = days[index].date
                    programmaticScrollTarget = days[index].id
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.055)).frame(height: 1)
        }
        .zIndex(20)
    }

    private func itineraryDayScroller(
        trip: SharedTripSnapshot,
        days: [TripDaySnapshot]
    ) -> some View {
        let currentOrNextCardID = ItineraryListPresentation.currentOrNextCardID(
            in: days,
            now: itineraryNow
        )
        let cityByDate = ItineraryListPresentation.cityLabels(
            in: days,
            resolvedCityByDate: itineraryResolvedCityByDate,
            fallbackDestination: trip.destination
        )
        // Computed once per data change instead of inside every day
        // section's body — see projectedMultiDayCardsByDay.
        let projectedByDayID = ItineraryListPresentation.projectedMultiDayCardsByDay(in: days)
        // 非机票卡的近似当地时间（最近的带时区机场），同样只在数据变化时算一次。
        let timeZoneByCardID = ItineraryLocalTime.timeZoneByCardID(in: days)

        return ScrollViewReader { scrollProxy in
            ScrollView {
                ItineraryScrollViewBridge(
                    controller: itineraryListScrollController,
                    isDragLocked: draggedListCard != nil
                )
                .frame(height: 0)
                .allowsHitTesting(false)

                if !appleSignIn.isAuthenticated {
                    signInBanner
                        .padding(.top, 12)
                }

                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.id) { day in
                        Section {
                            itineraryDayContent(
                                trip: trip,
                                day: day,
                                days: days,
                                currentOrNextCardID: currentOrNextCardID,
                                projectedOccurrences: projectedByDayID[day.id] ?? [],
                                timeZoneByCardID: timeZoneByCardID
                            )
                        } header: {
                            itineraryDayHeader(day, city: cityByDate[day.date])
                                .id(day.id)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ItineraryDayHeaderOffsetsPreferenceKey.self,
                                            value: [day.id: proxy.frame(in: .named("itinerary-day-scroll")).minY]
                                        )
                                    }
                                }
                        }
                        .zIndex(draggedListCard?.dayID == day.id ? 100 : 0)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 112)
            }
            .coordinateSpace(name: "itinerary-day-scroll")
            .scrollPosition($itineraryScrollPosition)
            .scrollIndicators(.hidden)
            .background(JourneyPalette.listSurface)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20,
                    style: .continuous
                )
            )
            .padding(.horizontal, 16)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ItineraryScrollViewportFramePreferenceKey.self,
                        value: proxy.frame(in: .named("itinerary-list-root"))
                    )
                }
            }
            .onScrollGeometryChange(for: ItineraryScrollMetrics.self) { geometry in
                ItineraryScrollMetrics(
                    // A changing offset in this Equatable transform would
                    // publish state for every normal scroll frame. Offset is
                    // only needed while a card drag is active.
                    offsetY: draggedListCard == nil ? 0 : geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, metrics in
                guard draggedListCard != nil else { return }
                itineraryScrollOffsetY = metrics.offsetY
                itineraryScrollContentHeight = metrics.contentHeight
                itineraryScrollViewportHeight = metrics.viewportHeight
                if draggedListCard != nil {
                    refreshDragDestinationForCurrentScroll()
                }
            }
            .onChange(of: programmaticScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth(duration: 0.34)) {
                    scrollProxy.scrollTo(target, anchor: .top)
                }
            }
            .onPreferenceChange(ItineraryDayHeaderOffsetsPreferenceKey.self) { offsets in
                updateSelectedDay(from: offsets, days: days)
            }
            .onPreferenceChange(ItineraryCardFramesPreferenceKey.self) { frames in
                itineraryListGeometryCache.cardFrames = frames
                settleReleasedListCardIfReady(using: frames)
            }
            .onPreferenceChange(ItineraryDayFramesPreferenceKey.self) { frames in
                itineraryListGeometryCache.dayFrames = frames
            }
            .onPreferenceChange(ItineraryScrollViewportFramePreferenceKey.self) { frame in
                itineraryScrollViewportFrame = frame
            }
            .task(id: ItineraryListPresentation.cityResolutionKey(for: days)) {
                let resolved = await ItineraryDayCityResolver.resolveCities(for: days)
                guard !Task.isCancelled else { return }
                itineraryResolvedCityByDate = resolved
            }
            .task(id: ItineraryListPresentation.flightAirportResolutionKey(for: days)) {
                let flights = days.flatMap(\.cards).filter { $0.kind == .flight }
                guard !flights.isEmpty else { return }
                let resolutions = await AppleMapService.resolveFlightAirportLocations(cards: flights)
                guard !Task.isCancelled else { return }
                syncEngine.cacheFlightAirportLocations(from: resolutions)
            }
        }
    }

    private func itineraryDayHeader(
        _ day: TripDaySnapshot,
        city: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ItineraryListPresentation.monthDay(for: day))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)

            Text(ItineraryListPresentation.weekday(for: day))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            if let city, !city.isEmpty {
                Text(city)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .background(JourneyPalette.listSurface)
        .contentShape(Rectangle())
        .contextMenu {
            Button("itinerary.addCardMenu", systemImage: "plus") { activeCardEditor = .create(day) }
            Button("itinerary.editDateMenu", systemImage: "calendar") { activeDaySheet = .edit(day) }
            Button("itinerary.deleteDateMenu", systemImage: "trash", role: .destructive) { dayPendingDeletion = day }
                .disabled(day.serverID == nil && syncEngine.isUserAuthenticated)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("itinerary.cardHint"))
    }

    @ViewBuilder
    private func itineraryDayContent(
        trip: SharedTripSnapshot,
        day: TripDaySnapshot,
        days: [TripDaySnapshot],
        currentOrNextCardID: UUID?,
        projectedOccurrences: [ItineraryListPresentation.ProjectedCardOccurrence],
        timeZoneByCardID: [UUID: TimeZone]
    ) -> some View {
        let cards = orderedListCards(for: day)
        // Multi-day projections (an overnight flight, a hotel night) merge
        // into the day's own chronological list instead of trailing after it.
        let listItems = ItineraryListPresentation.mergedDayListItems(
            ownCards: cards,
            projectedOccurrences: projectedOccurrences,
            day: day
        )
        VStack(alignment: .leading, spacing: ItineraryCardRailLayout.spacing) {
            if cards.isEmpty, projectedOccurrences.isEmpty {
                Button {
                    activeCardEditor = .create(day)
                } label: {
                    Label(
                        draggedListCardDestinationDayID == day.id ? "itinerary.dropHere" : "itinerary.emptyDayButton",
                        systemImage: draggedListCardDestinationDayID == day.id ? "arrow.down.to.line" : "plus.circle"
                    )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(draggedListCardDestinationDayID == day.id ? .orange : .white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 78)
                        // 与卡片列左缘对齐：留出左侧类别轨道的宽度（轨道关闭时不缩进）。
                        .padding(.leading, showsCardRail ? ItineraryCardRailLayout.width + ItineraryCardRailLayout.spacing : 0)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(listItems.enumerated()), id: \.element.id) { itemIndex, item in
                    // 左侧类别轨道（机票/酒店/景点 icon + 起止当地时间 + 连接
                    // 虚线）随每行卡片绘制：卡片列整体右移缩窄、左侧留白，类别
                    // 提示由轨道承担。设置中关闭后回到满宽卡片 + 卡内类别标记。
                    HStack(alignment: .top, spacing: ItineraryCardRailLayout.spacing) {
                        if showsCardRail {
                            ItineraryCardRail(
                                kind: item.card.kind,
                                showsConnector: itemIndex < listItems.count - 1,
                                startTime: ItineraryLocalTime.railStartTime(
                                    for: item.card,
                                    timeZone: timeZoneByCardID[item.card.id]
                                ),
                                endTime: ItineraryLocalTime.railEndTime(
                                    for: item.card,
                                    nextCard: itemIndex + 1 < listItems.count
                                        ? listItems[itemIndex + 1].card
                                        : nil,
                                    transitSeconds: itineraryTransitSecondsByCardID[item.card.id],
                                    timeZone: timeZoneByCardID[item.card.id]
                                )
                            )
                        }

                        if let ownIndex = item.ownIndex {
                            VStack(alignment: .leading, spacing: 10) {
                                itineraryCompactCard(
                                    item.card,
                                    index: ownIndex,
                                    day: day,
                                    cards: cards,
                                    days: days,
                                    currentOrNextCardID: currentOrNextCardID,
                                    timeZone: timeZoneByCardID[item.card.id] ?? ItineraryLocalTime.deviceTimeZone
                                )

                                // Route legs connect adjacent cards using the point
                                // where the previous card ends and the next begins.
                                // A flight therefore contributes its arrival airport
                                // as an origin, or its departure airport as a destination.
                                if itemIndex + 1 < listItems.count,
                                   let nextIndex = listItems[itemIndex + 1].ownIndex,
                                   nextIndex == ownIndex + 1,
                                   let originPoint = ItineraryListPresentation.legOriginPoint(for: item.card),
                                   let destinationPoint = ItineraryListPresentation.legDestinationPoint(for: listItems[itemIndex + 1].card) {
                                    CardLegEstimateView(
                                        originCard: item.card,
                                        destinationCard: listItems[itemIndex + 1].card,
                                        originPoint: originPoint,
                                        destinationPoint: destinationPoint,
                                        presentation: .itineraryList,
                                        onDurationChange: { seconds in
                                            // 上报本段交通耗时：轨道底部时间据此回推「最晚出发时刻」。
                                            if let seconds {
                                                itineraryTransitSecondsByCardID[item.card.id] = seconds
                                            } else {
                                                itineraryTransitSecondsByCardID.removeValue(forKey: item.card.id)
                                            }
                                        }
                                    )
                                    .id("\(CardLegStore.legKey(origin: item.card, destination: listItems[itemIndex + 1].card))-\(routeRefreshRevision)")
                                    .padding(.horizontal, 2)
                                }
                            }
                            .offset(y: placeholderOffset(for: item.card, in: day, cards: cards))
                            .animation(.snappy(duration: 0.2), value: draggedListCardDestinationIndex)
                            .animation(.snappy(duration: 0.2), value: draggedListCardDestinationDayID)
                            .zIndex(draggedListCard?.cardID == item.card.id ? 100 : 0)
                        } else {
                            // 跨天卡的投影片段（酒店多晚/过夜航班）同样支持左滑
                            // 编辑/询问/删除——操作作用于底层卡；长按拖动排序仍
                            // 从源日的那张卡发起（投影不报告拖拽命中 frame）。
                            itinerarySwipeableCard(
                                item.card,
                                index: itemIndex,
                                day: day,
                                days: days,
                                currentOrNextCardID: nil,
                                timeZone: timeZoneByCardID[item.card.id] ?? ItineraryLocalTime.deviceTimeZone,
                                progressLabel: itineraryCardProgressLabel(item.progress)
                            )
                            .accessibilityHint(
                                item.isHotelNight
                                    ? Text("itinerary.projectedHotelNightHint")
                                    : Text("itinerary.projectedMultiDayHint")
                            )
                        }
                    }
                }
            }

            if !cards.isEmpty,
               draggedListCardDestinationDayID == day.id,
               draggedListCard?.dayID != day.id {
                Color.clear
                    .frame(height: (draggedListCardStartFrame?.height ?? 72) + 10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .background(JourneyPalette.listSurface)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ItineraryDayFramesPreferenceKey.self,
                    value: [day.id: proxy.frame(in: .named("itinerary-list-root"))]
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    draggedListCardDestinationDayID == day.id && draggedListCard?.dayID != day.id
                        ? Color.orange.opacity(0.8)
                        : .clear,
                    lineWidth: 2
                )
        }
    }

    @ViewBuilder
    private func itineraryCompactCard(
        _ card: TravelCardSnapshot,
        index: Int,
        day: TripDaySnapshot,
        cards: [TravelCardSnapshot],
        days: [TripDaySnapshot],
        currentOrNextCardID: UUID?,
        timeZone: TimeZone
    ) -> some View {
        let supportsLongPressDrag = ItineraryCardDragPolicy.allowsLongPressDrag(card)
        let canReorder = supportsLongPressDrag
            && (!syncEngine.isUserAuthenticated || cards.allSatisfy { $0.serverID != nil })
        let isDragging = draggedListCard?.cardID == card.id || settlingListCard?.card.id == card.id

        itinerarySwipeableCard(
            card,
            index: index,
            day: day,
            days: days,
            currentOrNextCardID: currentOrNextCardID,
            timeZone: timeZone
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ItineraryCardFramesPreferenceKey.self,
                    value: [card.id: proxy.frame(in: .named("itinerary-list-root"))]
                )
            }
        }
        .opacity(isDragging ? 0 : 1)
        .accessibilityHint(
            Text(LocalizedStringKey(
                supportsLongPressDrag
                    ? (canReorder ? "itinerary.cardDetailHint" : "itinerary.cardDetailHintSyncing")
                    : "itinerary.cardDetailHintFixed"
            ))
        )
    }

    private func itinerarySwipeableCard(
        _ card: TravelCardSnapshot,
        index: Int,
        day: TripDaySnapshot,
        days: [TripDaySnapshot],
        currentOrNextCardID: UUID?,
        timeZone: TimeZone,
        progressLabel: String? = nil
    ) -> some View {
        let swipeOffset = listCardSwipeOffset(for: card.id)
        let revealedWidth = -swipeOffset
        let actionVisibility = ItineraryCardSwipeInteraction.actionVisibility(
            revealedWidth: revealedWidth
        )
        let actionsAreOpen = revealedListCardID == card.id && listCardSwipeGestureCardID == nil

        return ZStack(alignment: .trailing) {
            Button {
                closeListCardActions()
                cardPendingDeletion = card
            } label: {
                Image("icon-delete-outline")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .frame(width: ItineraryCardSwipeInteraction.actionWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(
                width: ItineraryCardSwipeInteraction.actionButtonWidth,
                alignment: .trailing
            )
            .background(
                Color(red: 213 / 255, green: 0, blue: 55 / 255),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .accessibilityLabel(Text("itinerary.swipeDeleteA11y"))
            .opacity(actionVisibility)
            .allowsHitTesting(actionsAreOpen)

            Button {
                openAgent(for: card, in: day)
            } label: {
                Image("icon-chat-outline")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .frame(width: ItineraryCardSwipeInteraction.actionWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(
                width: ItineraryCardSwipeInteraction.actionButtonWidth,
                alignment: .trailing
            )
            .background(
                Color(red: 1, green: 110 / 255, blue: 0),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .offset(x: ItineraryCardSwipeInteraction.drawerOffset(
                slotFromTrailing: 1,
                revealedWidth: revealedWidth
            ))
            .accessibilityLabel(Text("itinerary.swipeAskA11y"))
            .opacity(actionVisibility)
            .allowsHitTesting(actionsAreOpen)

            Button {
                closeListCardActions()
                activeCardEditor = .edit(day, card)
            } label: {
                Image("icon-edit-outline")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .frame(width: ItineraryCardSwipeInteraction.actionWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(
                width: ItineraryCardSwipeInteraction.actionButtonWidth,
                alignment: .trailing
            )
            .background(
                Color(red: 71 / 255, green: 71 / 255, blue: 71 / 255),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 15,
                    style: .continuous
                )
            )
            .offset(x: ItineraryCardSwipeInteraction.drawerOffset(
                slotFromTrailing: 2,
                revealedWidth: revealedWidth
            ))
            .accessibilityLabel(Text("itinerary.swipeEditA11y"))
            .opacity(actionVisibility)
            .allowsHitTesting(actionsAreOpen)

            itineraryCompactCardContent(
                card,
                index: index,
                showsTimeAccent: currentOrNextCardID == card.id,
                progressLabel: progressLabel ?? itineraryCardProgressLabel(
                    ItineraryListPresentation.cardProgress(
                        for: card,
                        // Own-day row: the card's source day is `day` itself,
                        // so skip the cross-day lookup.
                        sourceDay: day,
                        targetDay: day
                    )
                ),
                timeZone: timeZone
            )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 15,
                        style: .continuous
                    )
                )
                .offset(x: swipeOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            ItineraryHorizontalPanGesture(
                isEnabled: draggedListCard == nil && longPressedListCardID != card.id,
                actionsAlreadyRevealed: revealedListCardID == card.id,
                onChanged: { translation in
                    handleListCardSwipeChanged(card, translation: translation)
                },
                onEnded: { translation, predictedTranslation in
                    handleListCardSwipeEnded(
                        card,
                        translation: translation,
                        predictedTranslation: predictedTranslation
                    )
                },
                onCancelled: {
                    handleListCardSwipeCancelled(card)
                }
            )
        )
        .accessibilityAction(named: Text("common.edit")) {
            closeListCardActions()
            activeCardEditor = .edit(day, card)
        }
        .accessibilityAction(named: Text("itinerary.swipeAskA11y")) {
            openAgent(for: card, in: day)
        }
        .accessibilityAction(named: Text("common.delete")) {
            closeListCardActions()
            cardPendingDeletion = card
        }
        .animation(.snappy(duration: 0.22), value: revealedListCardID)
    }

    @ViewBuilder
    private func itineraryCompactCardContent(
        _ card: TravelCardSnapshot,
        index: Int,
        showsTimeAccent: Bool,
        progressLabel: String? = nil,
        timeZone: TimeZone = ItineraryLocalTime.deviceTimeZone
    ) -> some View {
        if card.kind == .flight {
            itineraryFlightCardContent(card, isActive: showsTimeAccent, progressLabel: progressLabel)
        } else if card.kind == .hotel {
            itineraryHotelCardContent(
                card,
                isActive: showsTimeAccent,
                progressLabel: progressLabel,
                timeZone: timeZone
            )
        } else {
            ZStack(alignment: .leading) {
                if showsTimeAccent {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(PrimaryTabPalette.accent)
                }

                Group {
                    if card.showLargeImage, CardImageURL.resolve(card.images?.first) != nil {
                        itineraryLargeImageCardContent(
                            card,
                            index: index,
                            progressLabel: progressLabel,
                            timeZone: timeZone
                        )
                    } else {
                        itineraryOrdinaryCardContent(
                            card,
                            index: index,
                            progressLabel: progressLabel,
                            timeZone: timeZone
                        )
                    }
                }
                .padding(.leading, showsTimeAccent ? 6 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func itineraryFlightCardContent(
        _ card: TravelCardSnapshot,
        isActive: Bool,
        progressLabel: String?
    ) -> some View {
        let price = compactCardPrice(for: card)
        let summary = ItineraryListPresentation.cardSummary(for: card)
        // 起降各自按机场当地时间显示（时区来自 /v1/airports 缓存）。
        let originTimeZone = ItineraryLocalTime.startTimeZone(for: card)
        let destinationTimeZone = ItineraryLocalTime.endTimeZone(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                showCardDetail(card)
            }
        } label: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    if let progressLabel {
                        itineraryProgressBadge(progressLabel)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        AirlineLogoBadge(
                            logoURL: itineraryAirlineLogoURL(for: card),
                            size: 32,
                            width: 68,
                            cornerRadius: 10
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            // 左侧轨道隐藏时，卡内恢复「机票」类别标记；
                            // 轨道显示时由轨道 icon 承担，卡内不再重复。
                            if !showsCardRail {
                                Label(card.kind.title, systemImage: "airplane.departure")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(PrimaryTabPalette.accent)
                            }
                            Text(itineraryFlightNumber(for: card))
                                .font(.subheadline.monospaced().weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let ticketNumber = card.ticketNumber?.nilIfEmpty {
                                HStack(spacing: 4) {
                                    Text("flightticket.ticketNumber")
                                        .font(.caption2)
                                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                                    Text(ticketNumber)
                                        .font(.caption.monospaced().weight(.semibold))
                                        .foregroundStyle(PrimaryTabPalette.accent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                        if let price {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(card.actualPriceMinor == nil ? String(localized: "travelcard.estimateLabel") : String(localized: "travelcard.actualLabel"))
                                    .font(.caption2)
                                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                                Text(price)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 0) {
                        itineraryFlightAirportBlock(
                            airport: card.fromAirport,
                            time: ItineraryLocalTime.shortTime(card.startAt, in: originTimeZone),
                            alignment: .leading
                        )
                        .frame(width: 86)
                        VStack(spacing: 5) {
                            itineraryFlightArcConnector(
                                durationText: itineraryFlightDuration(for: card)
                            )
                            Text(ItineraryLocalTime.monthDay(card.startAt, in: originTimeZone))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)
                        itineraryFlightAirportBlock(
                            airport: card.toAirport,
                            time: card.endAt.map {
                                ItineraryLocalTime.shortTime($0, in: destinationTimeZone)
                            } ?? String(localized: "agent.timePending"),
                            alignment: .trailing
                        )
                        .frame(width: 86)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .background(
                        Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )

                    if let summary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .lineSpacing(2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 乘机人行右侧常驻「查看详情」入口；原票券底栏（航司名 +
                    // 详情）已移除以缩减高度，点击卡片任意处同样进入详情。
                    HStack(spacing: 8) {
                        if let passengers = itinerarySharedPassengers(for: card) {
                            Text(passengers)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Text("travelcard.viewDetails")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // 与活动卡同一配色（此前为深蓝票券底色）。
                JourneyPalette.cardSurface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(PrimaryTabPalette.accent)
                        .frame(width: 5)
                        .padding(.vertical, 12)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(ItineraryCardNoFadeButtonStyle())
    }

    /// 酒店专属列表卡：突出房型、价格与入住/退房时间（头部+价格 → 关键字段
    /// → 双端点时间线）。原底部「查看详情」行已移除以缩减高度——点击卡片
    /// 任意处即可进入详情。
    private func itineraryHotelCardContent(
        _ card: TravelCardSnapshot,
        isActive: Bool,
        progressLabel: String?,
        timeZone: TimeZone
    ) -> some View {
        let price = compactCardPrice(for: card)
        let summary = ItineraryListPresentation.cardSummary(for: card)
        let nights = itineraryHotelNights(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                showCardDetail(card)
            }
        } label: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    if let progressLabel {
                        itineraryProgressBadge(progressLabel)
                    }
                    HStack(alignment: .top, spacing: 11) {
                        // 轨道隐藏时恢复卡内床铺徽章（与机票卡同款处理）。
                        if !showsCardRail {
                            Image(systemName: "bed.double.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                                .frame(width: 38, height: 38)
                                .background(
                                    PrimaryTabPalette.accent.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let placeName = card.place?.name.nilIfEmpty {
                                Text(placeName)
                                    .font(.caption)
                                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let price {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(card.actualPriceMinor == nil ? String(localized: "travelcard.estimateLabel") : String(localized: "travelcard.actualLabel"))
                                    .font(.caption2)
                                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                                Text(price)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    // 房型：酒店卡的核心字段，用主题色胶囊突出（同进度徽章样式）。
                    if let roomType = card.roomType?.nilIfEmpty {
                        Text(roomType)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PrimaryTabPalette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                PrimaryTabPalette.accent.opacity(0.14),
                                in: Capsule(style: .continuous)
                            )
                    }

                    // 入住/退房双端点 + 中段「N 晚」，对应机票卡的航线时间线。
                    // 日期按酒店当地时间显示（近似自最近的带时区机场）。
                    HStack(alignment: .center, spacing: 9) {
                        itineraryHotelStayBlock(
                            label: "hotelcard.checkIn",
                            date: card.startAt,
                            time: card.checkInTime,
                            alignment: .leading,
                            timeZone: timeZone
                        )
                        VStack(spacing: 6) {
                            if let nights {
                                Text(String(format: String(localized: "hotelcard.nights"), nights))
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(PrimaryTabPalette.accent, in: Capsule())
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color.white.opacity(0.24)).frame(width: 4, height: 4)
                                Rectangle().fill(Color.white.opacity(0.17)).frame(height: 1)
                                if !showsCardRail {
                                    Image(systemName: "bed.double")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(PrimaryTabPalette.accent)
                                }
                                Rectangle().fill(Color.white.opacity(0.17)).frame(height: 1)
                                Circle().fill(Color.white.opacity(0.24)).frame(width: 4, height: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        itineraryHotelStayBlock(
                            label: "hotelcard.checkOut",
                            date: card.endAt ?? card.startAt,
                            time: card.checkOutTime,
                            alignment: .trailing,
                            timeZone: timeZone
                        )
                    }

                    if let summary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .lineSpacing(2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                itineraryHotelCardBackground(card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle()
                        .fill(PrimaryTabPalette.accent)
                        .frame(width: 5)
                        .padding(.vertical, 12)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(ItineraryCardNoFadeButtonStyle())
    }

    @ViewBuilder
    private func itineraryHotelCardBackground(_ card: TravelCardSnapshot) -> some View {
        if CardImageURL.resolve(card.images?.first) != nil {
            ZStack {
                GeometryReader { proxy in
                    itineraryCardCover(card)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.42),
                        Color(red: 0.035, green: 0.055, blue: 0.085).opacity(0.78),
                        Color.black.opacity(0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            LinearGradient(
                colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// 入住/退房端点块：标签 + 日期（同机票机场码的圆角粗体）+ 政策时间。
    private func itineraryHotelStayBlock(
        label: LocalizedStringKey,
        date: Date,
        time: String?,
        alignment: HorizontalAlignment,
        timeZone: TimeZone
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
            // 复用机票卡的月日格式，保证两种卡片时间线视觉一致。
            Text(ItineraryLocalTime.monthDay(date, in: timeZone))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let time {
                Text(time)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    /// 入住到退房的整晚数：优先用 endAt-startAt 的日期差；缺失时退回
    /// stayDurationMinutes 换算（不足一天按一晚计）。都无法确定时返回 nil，
    /// 时间线中段只保留床铺虚线。
    private func itineraryHotelNights(for card: TravelCardSnapshot) -> Int? {
        if let end = card.endAt, end > card.startAt,
           let days = Calendar.current.dateComponents([.day], from: card.startAt, to: end).day,
           days > 0 {
            return days
        }
        guard let minutes = card.stayDurationMinutes, minutes > 0 else { return nil }
        return max(1, Int((Double(minutes) / 1440).rounded()))
    }

    private func itinerarySharedPassengers(for card: TravelCardSnapshot) -> String? {
        guard syncEngine.isUserAuthenticated, sharedMemberCount > 1,
              card.kind == .flight,
              let passengers = card.passengers?.nilIfEmpty else { return nil }
        return String(format: String(localized: "itinerary.passengersRow"), passengers)
    }

    private func itineraryFlightAirportBlock(
        airport: String?,
        time: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(AgentFlightDisplay.airportCode(airport))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(airport?.nilIfEmpty ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(time)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func itineraryAirlineLogoURL(for card: TravelCardSnapshot) -> URL? {
        if let url = CardImageURL.resolve(card.airlineLogoURL) { return url }
        let code = card.airlineCode ?? AgentFlightDisplay.airlineCode(fromBookingCode: card.bookingCode)
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }

    private func itineraryFlightNumber(for card: TravelCardSnapshot) -> String {
        card.bookingCode?.nilIfEmpty
            ?? card.airlineCode?.nilIfEmpty
            ?? String(localized: "agent.flightNumberPending")
    }

    /// 起降时间齐全且不超过一整天时显示飞行时长；否则中段胶囊只保留
    /// 飞机图标。与 FlightTicketPopup 的时长口径一致。
    private func itineraryFlightDuration(for card: TravelCardSnapshot) -> String? {
        ItineraryFlightCardPresentation.durationText(startAt: card.startAt, endAt: card.endAt)
    }

    /// 航线中段（参考票券样式）：两端圆点之间用上拱虚线弧线连接起降地，
    /// 弧线顶点悬浮飞行时长胶囊（时长 + 飞机图标）。
    private func itineraryFlightArcConnector(durationText: String?) -> some View {
        GeometryReader { proxy in
            let height: CGFloat = 23
            let width = max(12, proxy.size.width)
            ZStack(alignment: .top) {
                ZStack(alignment: .topLeading) {
                    ItineraryFlightArcShape()
                        .stroke(
                            Color.white.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4])
                        )
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .position(x: 2, y: height - 2)
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .position(x: width - 2, y: height - 2)
                }

                HStack(spacing: 4) {
                    if let durationText {
                        Text(durationText)
                            .font(.caption2.monospacedDigit().weight(.bold))
                    }
                    Image(systemName: "airplane")
                        .font(.system(size: 9, weight: .bold))
                        .padding(durationText == nil ? 3 : 0)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(PrimaryTabPalette.accent, in: Capsule())
            }
        }
        .frame(height: 23)
    }

    private func itineraryCardProgressLabel(
        _ progress: ItineraryListPresentation.CardProgress?
    ) -> String? {
        ItineraryListPresentation.progressLabel(progress)
    }

    private func itineraryProgressBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PrimaryTabPalette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                PrimaryTabPalette.accent.opacity(0.14),
                in: Capsule(style: .continuous)
            )
    }

    private func itineraryOrdinaryCardContent(
        _ card: TravelCardSnapshot,
        index: Int,
        progressLabel: String? = nil,
        timeZone: TimeZone = ItineraryLocalTime.deviceTimeZone
    ) -> some View {
        let summary = ItineraryListPresentation.cardSummary(for: card)
        let price = compactCardPrice(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                showCardDetail(card)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    itineraryCardCover(card)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "camera")
                            .font(.system(size: 17, weight: .medium))
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .semibold))
                            .offset(x: 5, y: -4)
                    }
                    .foregroundStyle(.white.opacity(0.64))
                    .frame(width: 25, height: 22)
                    .accessibilityHidden(true)
                }
                .frame(width: 64)

                VStack(alignment: .leading, spacing: 8) {
                    if let progressLabel {
                        itineraryProgressBadge(progressLabel)
                    }

                    Text(String(format: String(localized: "itinerary.cardTitle"), index + 1, card.title))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 14) {
                        compactCardMetadata(
                            icon: "icon-pin-outline",
                            text: ItineraryListPresentation.timeRange(for: card, timeZone: timeZone)
                        )

                        if let price {
                            compactCardMetadata(icon: "icon-ticket-outline", text: price)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let summary {
                        Text(summary)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineSpacing(2)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(
                                Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(
                JourneyPalette.cardSurface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
        }
        .buttonStyle(ItineraryCardNoFadeButtonStyle())
    }

    private func itineraryLargeImageCardContent(
        _ card: TravelCardSnapshot,
        index: Int,
        progressLabel: String? = nil,
        timeZone: TimeZone = ItineraryLocalTime.deviceTimeZone
    ) -> some View {
        let summary = ItineraryListPresentation.cardSummary(for: card)
        let price = compactCardPrice(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                showCardDetail(card)
            }
        } label: {
            VStack(alignment: .leading, spacing: ItineraryLargeImageCardLayout.contentSpacing) {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        // 竖版等 scaledToFill 图片的布局尺寸可能远大于可见卡面，
                        // 会把卡片撑宽。先按可见边界硬约束再叠层（与今日页
                        // POI 卡封面同一处理），使图片不再参与 ZStack 的取尺布局。
                        itineraryCardCover(card)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.12), .black.opacity(0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        VStack(alignment: .leading, spacing: 7) {
                            if let progressLabel {
                                itineraryProgressBadge(progressLabel)
                            }

                            Text(String(format: String(localized: "itinerary.cardTitle"), index + 1, card.title))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            HStack(spacing: 14) {
                                compactCardMetadata(
                                    icon: "icon-pin-outline",
                                    text: ItineraryListPresentation.timeRange(for: card)
                                )
                                if let price {
                                    compactCardMetadata(icon: "icon-ticket-outline", text: price)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 13)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(ItineraryLargeImageCardLayout.imageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let summary {
                    Text(summary)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(
                            Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                }
            }
            .padding(ItineraryLargeImageCardLayout.outerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                JourneyPalette.cardSurface,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
        }
        .buttonStyle(ItineraryCardNoFadeButtonStyle())
    }

    private func isCurrentOrNext(
        _ card: TravelCardSnapshot,
        in days: [TripDaySnapshot]
    ) -> Bool {
        ItineraryListPresentation.currentOrNextCardID(in: days, now: itineraryNow) == card.id
    }

    private func compactCardMetadata(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(icon)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.76))
    }

    private func compactCardPrice(for card: TravelCardSnapshot) -> String? {
        let currency = syncEngine.trip?.currency
        return CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency)
            ?? CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency)
            ?? CardPrice.format(minor: card.ticketPriceMinor, currency: card.priceCurrency ?? currency)
    }

    private func handleListCardSwipeChanged(_ card: TravelCardSnapshot, translation: CGFloat) {
        guard draggedListCard == nil, longPressedListCardID != card.id else { return }
        suppressListCardTap(card.id)
        if listCardSwipeGestureCardID == nil {
            listCardSwipeGestureCardID = card.id
            if revealedListCardID != card.id {
                revealedListCardID = nil
            }
        }
        guard listCardSwipeGestureCardID == card.id else { return }
        listCardSwipeTranslation = translation
    }

    private func handleListCardSwipeEnded(
        _ card: TravelCardSnapshot,
        translation: CGFloat,
        predictedTranslation: CGFloat
    ) {
        defer {
            resetListCardSwipeGesture()
            releaseListCardTapSuppression(card.id)
        }
        guard listCardSwipeGestureCardID == card.id else { return }

        let baseOffset = revealedListCardID == card.id
            ? -ItineraryCardSwipeInteraction.actionsWidth
            : 0
        let currentOffset = ItineraryCardSwipeInteraction.clampedOffset(
            baseOffset: baseOffset,
            translation: translation
        )
        let projectedOffset = ItineraryCardSwipeInteraction.projectedOffset(
            baseOffset: baseOffset,
            translation: translation,
            predictedTranslation: predictedTranslation
        )
        withAnimation(.snappy(duration: 0.22)) {
            revealedListCardID = ItineraryCardSwipeInteraction.shouldRevealActions(
                currentOffset: currentOffset,
                projectedOffset: projectedOffset
            ) ? card.id : nil
        }
    }

    private func handleListCardSwipeCancelled(_ card: TravelCardSnapshot) {
        guard listCardSwipeGestureCardID == card.id else { return }
        resetListCardSwipeGesture()
        releaseListCardTapSuppression(card.id)
    }

    private func listCardSwipeOffset(for cardID: UUID) -> CGFloat {
        let baseOffset = revealedListCardID == cardID
            ? -ItineraryCardSwipeInteraction.actionsWidth
            : 0
        guard listCardSwipeGestureCardID == cardID else { return baseOffset }
        return ItineraryCardSwipeInteraction.clampedOffset(
            baseOffset: baseOffset,
            translation: listCardSwipeTranslation
        )
    }

    private func closeListCardActions() {
        withAnimation(.snappy(duration: 0.22)) {
            revealedListCardID = nil
        }
        resetListCardSwipeGesture()
    }

    private func openAgent(for card: TravelCardSnapshot, in day: TripDaySnapshot) {
        closeListCardActions()
        agentSheet = ItineraryAgentSheet(
            initialMessage: ItineraryListPresentation.agentPrompt(for: card, date: day.date)
        )
    }

    private func showCardDetail(_ card: TravelCardSnapshot) {
        closeListCardActions()
        withAnimation(.snappy(duration: 0.26)) {
            if card.kind == .flight {
                flightDetailCard = card
            } else {
                detailCard = card
            }
        }
    }

    private func handleHeaderQuickAction(_ action: TodayQuickAction) {
        switch action {
        case .addCompanion:
            headerQuickAction = .addCompanion
            showsSharingSheet = true
        case .tripSelection:
            headerQuickAction = .tripSelection
            showsTripPicker = true
        case .reload:
            guard !isReloading else { return }
            headerQuickAction = .reload
            isReloading = true
            try? RouteCache(modelContext: modelContext).removeAll()
            CardLegStore(modelContext: modelContext).clearAllEstimateFailures()
            routeRefreshRevision &+= 1
            Task {
                async let retry: Void = syncEngine.retry()
                try? await Task.sleep(for: .seconds(0.75))
                await retry
                isReloading = false
                clearHeaderQuickAction(.reload)
            }
        case .settings:
            headerQuickAction = .settings
            showsSettings = true
        case .signIn:
            headerQuickAction = .signIn
            appleSignIn.errorMessage = nil
            showsSignIn = true
        }
    }

    private func clearHeaderQuickAction(_ action: TodayQuickAction) {
        guard headerQuickAction == action else { return }
        headerQuickAction = nil
    }

    private func selectTripFromPicker(_ summary: TripSummary) {
        guard tripBeingSelectedID == nil else { return }
        guard summary.id != syncEngine.selectedTripID else {
            showsTripPicker = false
            return
        }
        tripBeingSelectedID = summary.id
        Task {
            await syncEngine.selectTrip(summary.id)
            tripBeingSelectedID = nil
            showsTripPicker = false
        }
    }

    private func editSelectedTrip() {
        guard let selectedTripID = syncEngine.selectedTripID,
              let summary = syncEngine.trips.first(where: { $0.id == selectedTripID }) else { return }
        editingTrip = summary
    }

    /// 「新建旅程」与首页地图模式走同一条路：复位 Agent 会话、切回 .today
    /// section 并进入规划态——AgentHomeView(plansNewTrip:) 顶栏可返回当前
    /// 行程，确认创建后才切换选中行程。不再弹本地表单直接 createTrip。
    private func startNewTripPlanning() {
        agentSessionStore.startNewSession()
        withAnimation(.snappy(duration: 0.32)) {
            agentRunState.beginNewTripPlanning()
            section = .today
        }
    }

    private func resetListCardSwipeGesture() {
        listCardSwipeGestureCardID = nil
        listCardSwipeTranslation = 0
    }

    private func suppressListCardTap(_ cardID: UUID) {
        suppressedListCardTapReleaseTask?.cancel()
        suppressedListCardTapReleaseTask = nil
        suppressedListCardTapID = cardID
    }

    private func releaseListCardTapSuppression(_ cardID: UUID) {
        guard suppressedListCardTapID == cardID else { return }
        suppressedListCardTapReleaseTask?.cancel()
        suppressedListCardTapReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, suppressedListCardTapID == cardID else { return }
            suppressedListCardTapID = nil
            suppressedListCardTapReleaseTask = nil
        }
    }

    private func listCardDragTarget(
        at location: CGPoint,
        days: [TripDaySnapshot]
    ) -> (day: TripDaySnapshot, card: TravelCardSnapshot, cards: [TravelCardSnapshot])? {
        for day in days {
            let cards = orderedListCards(for: day)
            let canReorder = !syncEngine.isUserAuthenticated || cards.allSatisfy { $0.serverID != nil }
            guard canReorder else { continue }
            for card in cards.reversed() {
                if ItineraryCardDragPolicy.allowsLongPressDrag(card),
                   itineraryCardFrames[card.id]?.contains(location) == true {
                    return (day, card, cards)
                }
            }
        }
        return nil
    }

    private func listCardDragTarget(
        cardID: UUID?,
        days: [TripDaySnapshot]
    ) -> (day: TripDaySnapshot, card: TravelCardSnapshot, cards: [TravelCardSnapshot])? {
        guard let cardID else { return nil }
        for day in days {
            let cards = orderedListCards(for: day)
            if let card = cards.first(where: { $0.id == cardID }) {
                return (day, card, cards)
            }
        }
        return nil
    }

    private func handleRootListCardLongPressBegan(
        at location: CGPoint,
        days: [TripDaySnapshot]
    ) {
        guard let target = listCardDragTarget(at: location, days: days) else { return }
        handleListCardLongPressBegan(target.card, in: target.day)
    }

    private func handleRootListCardLongPressChanged(
        _ translation: CGSize,
        days: [TripDaySnapshot]
    ) {
        guard let target = listCardDragTarget(cardID: longPressedListCardID, days: days) else {
            cancelActiveListCardLongPress()
            return
        }
        handleListCardLongPressChanged(
            target.card,
            day: target.day,
            days: days,
            translation: translation
        )
    }

    private func handleRootListCardLongPressEnded(
        _ translation: CGSize,
        days: [TripDaySnapshot]
    ) {
        guard let target = listCardDragTarget(cardID: longPressedListCardID, days: days) else {
            cancelActiveListCardLongPress()
            return
        }
        handleListCardLongPressEnded(
            target.card,
            day: target.day,
            cards: target.cards,
            days: days,
            translation: translation
        )
    }

    private func cancelActiveListCardLongPress() {
        let cardID = longPressedListCardID
        if draggedListCard != nil {
            stopDragAutoScroll()
            withAnimation(.snappy(duration: 0.18)) {
                resetActiveListCardDrag()
            }
        }
        longPressedListCardID = nil
        if let cardID {
            releaseListCardTapSuppression(cardID)
        }
    }

    private func handleListCardLongPressBegan(
        _ card: TravelCardSnapshot,
        in day: TripDaySnapshot
    ) {
        longPressedListCardID = card.id
        suppressListCardTap(card.id)
        // Lift the card as soon as the long press is recognized. Translation
        // only moves an already-active drag; it must not gate the lift state.
        beginDragging(card, in: day)
    }

    private func handleListCardLongPressChanged(
        _ card: TravelCardSnapshot,
        day: TripDaySnapshot,
        days: [TripDaySnapshot],
        translation: CGSize
    ) {
        guard longPressedListCardID == card.id else { return }
        suppressListCardTap(card.id)
        guard draggedListCard?.cardID == card.id else { return }
        draggedListCardTranslation = translation
        draggedListCardFingerY = (draggedListCardStartFrame?.midY ?? 0) + translation.height
        updateDragAutoScroll(forFingerY: draggedListCardFingerY)
        refreshDragDestination(card: card, sourceDay: day, days: days)
    }

    private func handleListCardLongPressEnded(
        _ card: TravelCardSnapshot,
        day: TripDaySnapshot,
        cards: [TravelCardSnapshot],
        days: [TripDaySnapshot],
        translation: CGSize
    ) {
        defer { releaseListCardLongPress(card) }
        guard draggedListCard?.cardID == card.id else { return }
        finishDragging(card, in: day, cards: cards, days: days, translation: translation)
    }

    private func releaseListCardLongPress(_ card: TravelCardSnapshot) {
        if longPressedListCardID == card.id {
            longPressedListCardID = nil
        }
        releaseListCardTapSuppression(card.id)
    }

    private func beginDragging(_ card: TravelCardSnapshot, in day: TripDaySnapshot) {
        guard draggedListCard?.cardID != card.id else { return }
        closeListCardActions()
        clearSettlingListCard()
        if let metrics = itineraryListScrollController.metrics() {
            itineraryScrollOffsetY = metrics.offsetY
            itineraryScrollContentHeight = metrics.contentHeight
            itineraryScrollViewportHeight = metrics.viewportHeight
        }
        draggedListCard = ItineraryDraggedCard(dayID: day.id, cardID: card.id)
        draggedListCardBaseFrames = itineraryCardFrames
        draggedListCardBaseDayFrames = itineraryDayFrames
        draggedListCardStartFrame = draggedListCardBaseFrames[card.id]
        draggedListCardStartScrollOffsetY = itineraryScrollOffsetY
        draggedListCardTranslation = .zero
        draggedListCardDestinationDayID = day.id
        draggedListCardDestinationIndex = cardsIndex(of: card, in: day)
    }

    private func dragDestination(
        for card: TravelCardSnapshot,
        translation: CGSize,
        sourceDay: TripDaySnapshot,
        days: [TripDaySnapshot]
    ) -> ItineraryCardDropTarget? {
        guard let startFrame = draggedListCardStartFrame else { return nil }
        let draggedMidY = startFrame.midY + translation.height

        let targetDay = days
            .filter { dragAdjustedDayFrame(for: $0.id) != nil }
            .min { left, right in
                dayDistance(from: draggedMidY, to: dragAdjustedDayFrame(for: left.id))
                    < dayDistance(from: draggedMidY, to: dragAdjustedDayFrame(for: right.id))
            } ?? sourceDay
        let targetCards = orderedListCards(for: targetDay).filter { $0.id != card.id }
        let index = targetCards.firstIndex {
            guard let frame = dragAdjustedCardFrame(for: $0.id) else { return false }
            return draggedMidY < frame.midY
        } ?? targetCards.count
        return ItineraryCardDropTarget(dayID: targetDay.id, index: index)
    }

    private func dayDistance(from y: CGFloat, to frame: CGRect?) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        let expandedFrame = frame.insetBy(dx: 0, dy: -24)
        if expandedFrame.contains(CGPoint(x: expandedFrame.midX, y: y)) { return 0 }
        return min(abs(y - expandedFrame.minY), abs(y - expandedFrame.maxY))
    }

    private func finishDragging(
        _ card: TravelCardSnapshot,
        in day: TripDaySnapshot,
        cards: [TravelCardSnapshot],
        days: [TripDaySnapshot],
        translation: CGSize
    ) {
        stopDragAutoScroll()
        let destination = dragDestination(
            for: card,
            translation: translation,
            sourceDay: day,
            days: days
        )
        var didMove = false
        if let destination, destination.dayID == day.id {
            let currentOrder = cards.map(\.id)
            let newOrder = ItineraryListPresentation.movingCard(
                card.id,
                to: destination.index,
                in: currentOrder
            )
            if newOrder != currentOrder {
                didMove = beginSettlingListCard(
                    card,
                    from: day,
                    destination: destination,
                    translation: translation
                )
                withAnimation(.snappy(duration: 0.24)) {
                    visibleCardOrderByDay[day.id] = newOrder
                    resetActiveListCardDrag()
                }
                Task {
                    await syncEngine.reorderCards(in: day, orderedCardIDs: newOrder)
                }
            }
        } else if let destination,
                  let targetDay = days.first(where: { $0.id == destination.dayID }) {
            didMove = beginSettlingListCard(
                card,
                from: day,
                destination: destination,
                translation: translation
            )
            withAnimation(.snappy(duration: 0.24)) {
                resetActiveListCardDrag()
            }
            Task {
                await syncEngine.moveCard(
                    card,
                    from: day,
                    to: targetDay,
                    destinationIndex: destination.index
                )
            }
        }

        if !didMove {
            withAnimation(.snappy(duration: 0.18)) {
                resetActiveListCardDrag()
            }
        }
    }

    @discardableResult
    private func beginSettlingListCard(
        _ card: TravelCardSnapshot,
        from sourceDay: TripDaySnapshot,
        destination: ItineraryCardDropTarget,
        translation: CGSize
    ) -> Bool {
        guard let startFrame = draggedListCardStartFrame else { return false }
        settlingListCardTask?.cancel()
        settlingListCard = ItinerarySettlingCard(
            card: card,
            sourceDayID: sourceDay.id,
            destinationDayID: destination.dayID,
            destinationIndex: destination.index,
            startFrame: startFrame
        )
        settlingListCardCenter = ItineraryDragInteraction.releaseCenter(
            startFrame: startFrame,
            translation: translation
        )
        settlingListCardIsAnimating = false
        let cardID = card.id
        settlingListCardTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled,
                  settlingListCard?.card.id == cardID,
                  !settlingListCardIsAnimating else { return }
            clearSettlingListCard()
        }
        return true
    }

    private func settleReleasedListCardIfReady(using frames: [UUID: CGRect]) {
        guard let settlingListCard,
              !settlingListCardIsAnimating,
              let targetFrame = frames[settlingListCard.card.id],
              let destinationDay = syncEngine.trip?.days.first(where: {
                  $0.id == settlingListCard.destinationDayID
              }),
              destinationDay.cards.contains(where: { $0.id == settlingListCard.card.id }),
              let destinationDayFrame = itineraryDayFrames[settlingListCard.destinationDayID],
              destinationDayFrame.insetBy(dx: -12, dy: -12).contains(
                  CGPoint(x: targetFrame.midX, y: targetFrame.midY)
              ) else { return }

        let startCenter = CGPoint(
            x: settlingListCard.startFrame.midX,
            y: settlingListCard.startFrame.midY
        )
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        if settlingListCard.sourceDayID == settlingListCard.destinationDayID,
           hypot(targetCenter.x - startCenter.x, targetCenter.y - startCenter.y) < 1 {
            return
        }

        settlingListCardTask?.cancel()
        let cardID = settlingListCard.card.id
        settlingListCardTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, self.settlingListCard?.card.id == cardID else { return }
            animateReleasedListCardToCurrentFrame(cardID: cardID)
        }
    }

    private func animateReleasedListCardToCurrentFrame(cardID: UUID) {
        guard let settlingListCard,
              settlingListCard.card.id == cardID,
              !settlingListCardIsAnimating,
              let targetFrame = itineraryCardFrames[cardID],
              let destinationDayFrame = itineraryDayFrames[settlingListCard.destinationDayID],
              destinationDayFrame.insetBy(dx: -12, dy: -12).contains(
                  CGPoint(x: targetFrame.midX, y: targetFrame.midY)
              ) else {
            clearSettlingListCard()
            return
        }

        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        settlingListCardIsAnimating = true
        withAnimation(.snappy(duration: 0.28)) {
            settlingListCardCenter = targetCenter
        }
        settlingListCardTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.settlingListCard?.card.id == cardID else { return }
            clearSettlingListCard()
        }
    }

    private func resetActiveListCardDrag() {
        draggedListCard = nil
        draggedListCardTranslation = .zero
        draggedListCardStartFrame = nil
        draggedListCardDestinationDayID = nil
        draggedListCardDestinationIndex = nil
        draggedListCardBaseFrames = [:]
        draggedListCardBaseDayFrames = [:]
        draggedListCardFingerY = nil
    }

    private func clearSettlingListCard() {
        settlingListCardTask?.cancel()
        settlingListCardTask = nil
        settlingListCard = nil
        settlingListCardIsAnimating = false
        settlingListCardCenter = .zero
    }

    private func dragAdjustedCardFrame(for cardID: UUID) -> CGRect? {
        if let baseFrame = draggedListCardBaseFrames[cardID] {
            return baseFrame.offsetBy(
                dx: 0,
                dy: draggedListCardStartScrollOffsetY - itineraryScrollOffsetY
            )
        }
        return itineraryCardFrames[cardID]
    }

    private func dragAdjustedDayFrame(for dayID: UUID) -> CGRect? {
        if let baseFrame = draggedListCardBaseDayFrames[dayID] {
            return baseFrame.offsetBy(
                dx: 0,
                dy: draggedListCardStartScrollOffsetY - itineraryScrollOffsetY
            )
        }
        return itineraryDayFrames[dayID]
    }

    private func refreshDragDestination(
        card: TravelCardSnapshot,
        sourceDay: TripDaySnapshot,
        days: [TripDaySnapshot]
    ) {
        let destination = dragDestination(
            for: card,
            translation: draggedListCardTranslation,
            sourceDay: sourceDay,
            days: days
        )
        draggedListCardDestinationDayID = destination?.dayID
        draggedListCardDestinationIndex = destination?.index
    }

    private func refreshDragDestinationForCurrentScroll() {
        guard let draggedListCard,
              let trip = syncEngine.trip else { return }
        let days = trip.sortedDaysInDateRange
        guard let sourceDay = days.first(where: { $0.id == draggedListCard.dayID }),
              let card = sourceDay.cards.first(where: { $0.id == draggedListCard.cardID }) else { return }
        refreshDragDestination(card: card, sourceDay: sourceDay, days: days)
    }

    private func updateDragAutoScroll(forFingerY fingerY: CGFloat?) {
        guard let fingerY,
              draggedListCard != nil,
              itineraryScrollViewportFrame.height > 0 else {
            stopDragAutoScroll()
            return
        }

        let velocity = ItineraryDragInteraction.autoScrollVelocity(
            fingerY: fingerY,
            viewport: itineraryScrollViewportFrame
        )

        dragAutoScrollVelocity = velocity
        guard velocity != 0 else {
            stopDragAutoScroll()
            return
        }
        guard dragAutoScrollTask == nil else { return }

        dragAutoScrollTask = Task { @MainActor in
            while !Task.isCancelled, draggedListCard != nil {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { break }
                let scrollDelta = dragAutoScrollVelocity / 60
                if let actualOffset = itineraryListScrollController.scroll(by: scrollDelta) {
                    itineraryScrollOffsetY = actualOffset
                    refreshDragDestinationForCurrentScroll()
                    continue
                }
                let maximumOffset = max(0, itineraryScrollContentHeight - itineraryScrollViewportHeight)
                let nextOffset = min(
                    maximumOffset,
                    max(0, itineraryScrollOffsetY + scrollDelta)
                )
                if abs(nextOffset - itineraryScrollOffsetY) > 0.1 {
                    itineraryScrollOffsetY = nextOffset
                    itineraryScrollPosition.scrollTo(y: nextOffset)
                    refreshDragDestinationForCurrentScroll()
                }
            }
        }
    }

    private func stopDragAutoScroll() {
        dragAutoScrollVelocity = 0
        dragAutoScrollTask?.cancel()
        dragAutoScrollTask = nil
    }

    private func cardsIndex(of card: TravelCardSnapshot, in day: TripDaySnapshot) -> Int? {
        orderedListCards(for: day).firstIndex(where: { $0.id == card.id })
    }

    private func placeholderOffset(
        for card: TravelCardSnapshot,
        in day: TripDaySnapshot,
        cards: [TravelCardSnapshot]
    ) -> CGFloat {
        guard let draggedCard = draggedListCard,
              let destinationDayID = draggedListCardDestinationDayID,
              let destinationIndex = draggedListCardDestinationIndex,
              let cardIndex = cards.firstIndex(where: { $0.id == card.id }),
              let cardFrame = draggedListCardBaseFrames[card.id] else { return 0 }

        if day.id != draggedCard.dayID, day.id == destinationDayID, cardIndex >= destinationIndex {
            return (draggedListCardStartFrame?.height ?? 72) + 10
        }

        guard day.id == draggedCard.dayID,
              let sourceIndex = cards.firstIndex(where: { $0.id == draggedCard.cardID }) else { return 0 }

        if destinationDayID != draggedCard.dayID,
           cardIndex > sourceIndex,
           cards.indices.contains(cardIndex - 1),
           let previousFrame = draggedListCardBaseFrames[cards[cardIndex - 1].id] {
            return previousFrame.midY - cardFrame.midY
        }

        if destinationDayID == draggedCard.dayID,
           destinationIndex > sourceIndex,
           cardIndex > sourceIndex,
           cardIndex <= destinationIndex,
           cards.indices.contains(cardIndex - 1),
           let previousFrame = draggedListCardBaseFrames[cards[cardIndex - 1].id] {
            return previousFrame.midY - cardFrame.midY
        }

        if destinationDayID == draggedCard.dayID,
           destinationIndex < sourceIndex,
           cardIndex >= destinationIndex,
           cardIndex < sourceIndex,
           cards.indices.contains(cardIndex + 1),
           let nextFrame = draggedListCardBaseFrames[cards[cardIndex + 1].id] {
            return nextFrame.midY - cardFrame.midY
        }

        return 0
    }

    private func orderedListCards(for day: TripDaySnapshot) -> [TravelCardSnapshot] {
        let persistedOrder = ItineraryListPresentation.orderedCards(day.cards)
        guard let visibleOrder = visibleCardOrderByDay[day.id],
              visibleOrder.count == persistedOrder.count,
              Set(visibleOrder) == Set(persistedOrder.map(\.id)) else {
            return persistedOrder
        }

        let cardsByID = Dictionary(uniqueKeysWithValues: persistedOrder.map { ($0.id, $0) })
        return visibleOrder.compactMap { cardsByID[$0] }
    }

    @ViewBuilder
    private func itineraryCardCover(_ card: TravelCardSnapshot) -> some View {
        if let url = CardImageURL.resolve(card.images?.first) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    itineraryCardPlaceholder(card)
                }
            }
        } else {
            itineraryCardPlaceholder(card)
        }
    }

    private func itineraryCardPlaceholder(_ card: TravelCardSnapshot) -> some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.16), .white.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: card.kind.systemImage)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
        }
    }

    private func updateSelectedDay(
        from offsets: [UUID: CGFloat],
        days: [TripDaySnapshot]
    ) {
        guard !offsets.isEmpty else { return }

        if let target = programmaticScrollTarget {
            if let targetOffset = offsets[target], abs(targetOffset) < 2 {
                programmaticScrollTarget = nil
            } else {
                return
            }
        }

        let pinnedOrPastDay = days
            .compactMap { day -> (TripDaySnapshot, CGFloat)? in
                guard let offset = offsets[day.id] else { return nil }
                return (day, offset)
            }
            .filter { $0.1 <= 1 }
            .max { $0.1 < $1.1 }

        let nextDay = days.compactMap { day -> (TripDaySnapshot, CGFloat)? in
                guard let offset = offsets[day.id], offset > 1 else { return nil }
                return (day, offset)
            }
            .min { $0.1 < $1.1 }

        let visibleDay = pinnedOrPastDay?.0 ?? nextDay?.0

        if let visibleDay, visibleDay.date != selectedListDate {
            selectedListDate = visibleDay.date
        }
    }

    private func joinPendingInviteIfPossible() {
        guard let token = sharedLinkStore.pendingInviteToken,
              syncEngine.isUserAuthenticated,
              inviteBeingJoined != token else { return }
        inviteBeingJoined = token
        Task {
            let joined = await syncEngine.joinTrip(inviteToken: token)
            guard inviteBeingJoined == token else { return }
            inviteBeingJoined = nil
            if joined, sharedLinkStore.pendingInviteToken == token {
                sharedLinkStore.markInviteDelivered()
            }
        }
    }

    /// Compact Apple Sign-In banner shown at the top of the Journey tab when
    /// the user is not authenticated. It explains the local-only behavior and
    /// offers the system Sign-In with Apple button. Signing in is non-blocking:
    /// the tab and all local data remain usable while the sheet is presented.
    private var signInBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("itinerary.localModeTitle")
                        .font(.headline)
                    Text("itinerary.localModeDesc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ZStack {
                // Keep the native button mounted throughout authorization. Removing it
                // from the hierarchy in `onRequest` can prevent `onCompletion` from
                // delivering the Apple credential and leave the UI in a loading state.
                SignInWithAppleButton(.continue,
                                      onRequest: { request in
                                          appleSignIn.configure(request)
                                          Task { await appleSignIn.signIn(apiClient: APIClient()) }
                                      },
                                      onCompletion: { appleSignIn.handle(result: $0) })
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .allowsHitTesting(!appleSignIn.isSigningIn)

                if appleSignIn.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("itinerary.signingIn")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(Text("itinerary.signingInA11y"))
                    .allowsHitTesting(false)
                }
            }
            if let errorMessage = appleSignIn.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.indigo.opacity(0.3)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func tripHeader(_ trip: SharedTripSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.destination ?? String(localized: "itinerary.noDestination"))
                .font(.system(size: 39, weight: .black, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
            Text([trip.startDate, trip.endDate].compactMap { $0 }.joined(separator: " — "))
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
            Text(trip.currency ?? "")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(JourneyPalette.tripBlue, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.17), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button("common.edit") { editSelectedTrip() }
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(JourneyPalette.actionBlue, in: Capsule())
                .padding(18)
                .buttonStyle(.plain)
        }
    }

    private func timeline(_ trip: SharedTripSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("itinerary.timelineSection").font(.system(size: 30, weight: .black, design: .rounded))
                    Spacer()
                    Button("itinerary.addDateButton", systemImage: "plus") { activeDaySheet = .add }
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(JourneyPalette.controlFill, in: Capsule())
                        .overlay { Capsule().stroke(JourneyPalette.actionBlue.opacity(0.75), lineWidth: 1) }
                        .buttonStyle(.plain)
                }
                let days = trip.sortedDaysInDateRange
                ForEach(days, id: \.id) { day in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(day.date).font(.title2.weight(.black))
                            Spacer()
                            Button(role: .destructive) { dayPendingDeletion = day } label: { Image(systemName: "trash") }
                                .journeyRoundControl()
                                .disabled(day.serverID == nil && syncEngine.isUserAuthenticated)
                                .accessibilityLabel(Text("itinerary.deleteDateMenu"))
                            Button { activeCardEditor = .create(day) } label: { Image(systemName: "plus") }
                                .journeyRoundControl()
                                .accessibilityLabel(Text("itinerary.addCardMenu"))
                        }
                        Text("itinerary.cardsSection").font(.title3.weight(.black))
                        let cards = day.cards.sorted(by: Self.cardTimeOrder)
                        if !cards.isEmpty && !cards.contains(where: { $0.kind == .hotel }) {
                            Label("itinerary.noLodging", systemImage: "bed.double")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.38))
                        }
                        if cards.isEmpty {
                            Label("itinerary.noCards", systemImage: "rectangle.stack")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("itinerary.noCardsDesc")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { cardIndex, card in
                                HStack(alignment: .top, spacing: 10) {
                                    timelineTime(for: card)
                                    TravelCardView(
                                        card: card,
                                        canMoveUp: cardIndex > 0 && (card.serverID != nil || !syncEngine.isUserAuthenticated),
                                        canMoveDown: cardIndex < cards.count - 1 && (card.serverID != nil || !syncEngine.isUserAuthenticated),
                                        routeCards: routeCandidates(for: card, in: day, days: days),
                                        currency: trip.currency,
                                        showsTime: false,
                                        onEdit: { activeCardEditor = .edit(day, card) },
                                        onDelete: { cardPendingDeletion = card },
                                        onMove: { direction in Task { await syncEngine.moveCard(card, in: day, direction: direction) } },
                                        linkHandler: linkHandler
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .onTapGesture { showCardDetail(card) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint(Text(String(format: String(localized: "itinerary.openDetailHint"), card.title)))
                                }
                                if cardIndex < cards.count - 1,
                                   let originPoint = ItineraryListPresentation.legOriginPoint(for: card),
                                   let destinationPoint = ItineraryListPresentation.legDestinationPoint(for: cards[cardIndex + 1]) {
                                    CardLegEstimateView(
                                        originCard: card,
                                        destinationCard: cards[cardIndex + 1],
                                        originPoint: originPoint,
                                        destinationPoint: destinationPoint
                                    )
                                    .id("\(CardLegStore.legKey(origin: card, destination: cards[cardIndex + 1]))-\(routeRefreshRevision)")
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        dayExpensesSection(trip: trip, day: day)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(JourneyPalette.dayFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(JourneyPalette.dayBorder, lineWidth: 1)
                    }
                }
                if trip.days.isEmpty {
                    ContentUnavailableView("itinerary.noDatesTitle", systemImage: "calendar.badge.plus", description: Text("itinerary.noDatesDesc"))
                }
        }
    }

    /// Route legs must follow the visible chronological timeline. `position`
    /// remains a tie-breaker for cards that start at the same instant.
    private static func cardTimeOrder(_ left: TravelCardSnapshot, _ right: TravelCardSnapshot) -> Bool {
        if left.startAt != right.startAt { return left.startAt < right.startAt }
        if left.position != right.position { return left.position < right.position }
        return left.title.localizedStandardCompare(right.title) == .orderedAscending
    }

    private func timelineTime(for card: TravelCardSnapshot) -> some View {
        Text(Self.cardTimeFormatter.string(from: card.startAt))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.top, 18)
            .accessibilityLabel(Text(String(format: String(localized: "itinerary.startTimeA11y"), Self.cardTimeFormatter.string(from: card.startAt))))
    }

    /// 当日实际价支出：按 occurredOn == day.date 过滤，绑定到行程当日页。
    @ViewBuilder
    private func dayExpensesSection(trip: SharedTripSnapshot, day: TripDaySnapshot) -> some View {
        let expenses = trip.expenses.filter { $0.occurredOn == day.date }.sorted { $0.updatedAt > $1.updatedAt }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("itinerary.dayExpensesSection").font(.subheadline.weight(.semibold))
                Spacer()
                if let currency = trip.currency {
                    Text(ExpenseMoney.formatted(expenses.compactMap(\.amountForSettlement).reduce(Int64(0), +), currency: currency))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if expenses.isEmpty {
                Text("itinerary.dayExpensesEmpty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(expenses) { expense in
                    HStack(spacing: 8) {
                        Image(systemName: expense.category.systemImage)
                            .foregroundStyle(.secondary)
                        Text(expense.category.title).font(.subheadline)
                        if let note = expense.note, !note.isEmpty {
                            Text(String(format: String(localized: "itinerary.expenseNotePrefix"), note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let currency = trip.currency {
                            Text(ExpenseMoney.formatted(expense.amountMinor, currency: expense.currency))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }
            Button("itinerary.addExpenseButton", systemImage: "plus") {
                expenseEditorDate = Self.dayDate(from: day.date)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(JourneyPalette.controlFill, in: Capsule())
            .buttonStyle(.plain)
            .disabled(trip.currency == nil)
        }
    }

    private static let cardTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let itineraryDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayDate(from string: String) -> Date {
        itineraryDayFormatter.date(from: string) ?? .now
    }

    /// Keep the most likely next stops at the top of the route picker: other
    /// cards today (chronologically), then the immediately adjacent dates,
    /// then the remaining itinerary. Cards without a coordinate are filtered
    /// in RouteSheet.
    private func routeCandidates(for card: TravelCardSnapshot, in day: TripDaySnapshot, days: [TripDaySnapshot]) -> [TravelCardSnapshot] {
        guard let dayIndex = days.firstIndex(where: { $0.id == day.id }) else { return [] }
        var ordered = day.cards.sorted(by: Self.cardTimeOrder)
        for index in [dayIndex - 1, dayIndex + 1] where days.indices.contains(index) {
            ordered += days[index].cards.sorted(by: Self.cardTimeOrder)
        }
        for index in days.indices where index != dayIndex && index != dayIndex - 1 && index != dayIndex + 1 {
            ordered += days[index].cards.sorted(by: Self.cardTimeOrder)
        }
        return ordered.filter { $0.id != card.id }
    }

    private enum DaySheet: Identifiable {
        case add
        case edit(TripDaySnapshot)

        var id: UUID {
            switch self {
            case .add: return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            case .edit(let day): return day.id
            }
        }

        var day: TripDaySnapshot? {
            if case .edit(let day) = self { return day }
            return nil
        }
    }

    private enum CardEditorTarget: Identifiable {
        case create(TripDaySnapshot, initialURL: String? = nil)
        case edit(TripDaySnapshot, TravelCardSnapshot)

        var id: String {
            switch self {
            case .create(let day, let initialURL): "create-\(day.id.uuidString)-\(initialURL ?? "")"
            case .edit(_, let card): "edit-\(card.id.uuidString)"
            }
        }

        var day: TripDaySnapshot {
            switch self {
            case .create(let day, _), .edit(let day, _): day
            }
        }

        var card: TravelCardSnapshot? {
            if case .edit(_, let card) = self { return card }
            return nil
        }

        var initialURL: String? {
            if case .create(_, let initialURL) = self { return initialURL }
            return nil
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let statusText {
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .glassEffect(in: Capsule())
        }
    }

    private var statusText: String? {
        switch syncEngine.status {
        case .loading: return String(localized: "itinerary.statusLoading")
        case .synced: return nil
        case .syncing: return nil
        case .pending(let count): return String(format: String(localized: "itinerary.statusPending"), count)
        case .conflict: return String(localized: "itinerary.statusConflict")
        case .localOnly: return appleSignIn.isAuthenticated ? nil : String(localized: "itinerary.statusLocal")
        case .offline(let message), .failed(let message): return message
        }
    }
}

private enum JourneyPalette {
    static let tripBlue = Color(red: 0.36, green: 0.45, blue: 0.97)
    static let actionBlue = Color(red: 0.09, green: 0.20, blue: 0.68)
    static let toolbarFill = Color(red: 0.075, green: 0.075, blue: 0.08)
    static let controlFill = Color(red: 0.095, green: 0.10, blue: 0.13)
    static let dayFill = Color(red: 0.025, green: 0.03, blue: 0.06)
    static let dayBorder = Color(red: 0.17, green: 0.20, blue: 0.36)
    static let listSurface = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let cardSurface = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
}

private struct ItineraryCardNoFadeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct ItineraryHorizontalPanGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var actionsAlreadyRevealed: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ predictedTranslation: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.configuration = self
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            context.coordinator.configuration.onChanged(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            let predictedTranslation = translation + velocity * 0.12
            context.coordinator.configuration.onEnded(translation, predictedTranslation)
        case .cancelled, .failed:
            context.coordinator.configuration.onCancelled()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: ItineraryHorizontalPanGesture

        init(configuration: ItineraryHorizontalPanGesture) {
            self.configuration = configuration
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.isEnabled,
                  let panGesture = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let view = panGesture.view
            return ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: panGesture.velocity(in: view),
                actionsAlreadyRevealed: configuration.actionsAlreadyRevealed,
                touchLocationX: view.map { panGesture.location(in: $0).x },
                viewWidth: view?.bounds.width
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct ItineraryLongPressDragGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var canBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(configuration: self, converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.minimumPressDuration = 0.3
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.numberOfTouchesRequired = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.converter = context.converter
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began:
            coordinator.startLocation = recognizer.location(in: nil)
            coordinator.configuration.onBegan(coordinator.locationInListRoot())
        case .changed:
            coordinator.configuration.onChanged(coordinator.translation(for: recognizer))
        case .ended:
            coordinator.configuration.onEnded(coordinator.translation(for: recognizer))
            coordinator.startLocation = nil
        case .cancelled, .failed:
            coordinator.configuration.onCancelled()
            coordinator.startLocation = nil
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: ItineraryLongPressDragGesture
        var converter: CoordinateSpaceConverter
        var startLocation: CGPoint?

        init(
            configuration: ItineraryLongPressDragGesture,
            converter: CoordinateSpaceConverter
        ) {
            self.configuration = configuration
            self.converter = converter
        }

        func locationInListRoot() -> CGPoint {
            converter.location(in: .named("itinerary-list-root"))
        }

        func translation(for recognizer: UILongPressGestureRecognizer) -> CGSize {
            guard let startLocation else { return .zero }
            let location = recognizer.location(in: nil)
            return CGSize(
                width: location.x - startLocation.x,
                height: location.y - startLocation.y
            )
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.isEnabled,
                  gestureRecognizer is UILongPressGestureRecognizer else {
                return false
            }
            return configuration.canBegin(locationInListRoot())
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

@MainActor
final class ItineraryListScrollController: ObservableObject {
    private weak var scrollView: UIScrollView?
    private var isDragLocked = false

    func connect(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else {
            applyDragLock()
            return
        }
        self.scrollView?.panGestureRecognizer.isEnabled = true
        self.scrollView = scrollView
        applyDragLock()
    }

    func disconnect(from scrollView: UIScrollView) {
        guard self.scrollView === scrollView else { return }
        scrollView.panGestureRecognizer.isEnabled = true
        self.scrollView = nil
    }

    func setDragLocked(_ isDragLocked: Bool) {
        self.isDragLocked = isDragLocked
        applyDragLock()
    }

    @discardableResult
    func scroll(by delta: CGFloat) -> CGFloat? {
        guard let scrollView, abs(delta) > 0.001 else { return nil }
        scrollView.layoutIfNeeded()
        let insets = scrollView.adjustedContentInset
        let minimumOffsetY = -insets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        )
        let targetOffsetY = min(
            maximumOffsetY,
            max(minimumOffsetY, scrollView.contentOffset.y + delta)
        )
        guard abs(targetOffsetY - scrollView.contentOffset.y) > 0.05 else {
            return scrollView.contentOffset.y + insets.top
        }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
            animated: false
        )
        return targetOffsetY + insets.top
    }

    fileprivate func metrics() -> ItineraryScrollMetrics? {
        guard let scrollView else { return nil }
        let insets = scrollView.adjustedContentInset
        return ItineraryScrollMetrics(
            offsetY: scrollView.contentOffset.y + insets.top,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height
        )
    }

    private func applyDragLock() {
        guard let scrollView,
              scrollView.panGestureRecognizer.isEnabled == isDragLocked else { return }
        scrollView.panGestureRecognizer.isEnabled = !isDragLocked
    }
}

/// High-frequency geometry storage deliberately has no @Published fields.
/// Gesture handlers read the newest values, but normal scrolling does not
/// invalidate the SwiftUI hierarchy merely because frames moved on screen.
@MainActor
final class ItineraryListGeometryCache: ObservableObject {
    var cardFrames: [UUID: CGRect] = [:]
    var dayFrames: [UUID: CGRect] = [:]
}

private struct ItineraryScrollViewBridge: UIViewRepresentable {
    let controller: ItineraryListScrollController
    let isDragLocked: Bool

    func makeUIView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.controller = controller
        view.isDragLocked = isDragLocked
        return view
    }

    func updateUIView(_ view: TrackingView, context: Context) {
        view.controller = controller
        view.isDragLocked = isDragLocked
        view.connectToAncestorScrollView()
    }

    static func dismantleUIView(_ view: TrackingView, coordinator: Void) {
        if let scrollView = view.connectedScrollView {
            view.controller?.disconnect(from: scrollView)
        }
    }

    @MainActor
    final class TrackingView: UIView {
        weak var controller: ItineraryListScrollController?
        weak var connectedScrollView: UIScrollView?
        var isDragLocked = false {
            didSet { controller?.setDragLocked(isDragLocked) }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            connectToAncestorScrollView()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connectToAncestorScrollView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            connectToAncestorScrollView()
        }

        func connectToAncestorScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if connectedScrollView !== scrollView {
                        connectedScrollView = scrollView
                        controller?.connect(to: scrollView)
                    }
                    controller?.setDragLocked(isDragLocked)
                    return
                }
                ancestor = view.superview
            }

            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.connectedScrollView = scrollView
                        self.controller?.connect(to: scrollView)
                        self.controller?.setDragLocked(self.isDragLocked)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

private struct ItineraryDayHeaderOffsetsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] { [:] }

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ItineraryCardFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ItineraryDayFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ItineraryScrollViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

fileprivate struct ItineraryScrollMetrics: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
}

private struct ItineraryAgentSheet: Identifiable {
    let id = UUID()
    let initialMessage: String?
}

private struct ItineraryDraggedCard: Equatable {
    let dayID: UUID
    let cardID: UUID
}

private struct ItineraryCardDropTarget: Equatable {
    let dayID: UUID
    let index: Int
}

private struct ItinerarySettlingCard {
    let card: TravelCardSnapshot
    let sourceDayID: UUID
    let destinationDayID: UUID
    let destinationIndex: Int
    let startFrame: CGRect
}

enum ItineraryDragInteraction {
    static func releaseCenter(startFrame: CGRect, translation: CGSize) -> CGPoint {
        CGPoint(
            x: startFrame.midX + translation.width,
            y: startFrame.midY + translation.height
        )
    }

    static func autoScrollVelocity(
        fingerY: CGFloat,
        viewport: CGRect,
        minimumSpeed: CGFloat = 90,
        maximumSpeed: CGFloat = 720
    ) -> CGFloat {
        guard viewport.height > 0 else { return 0 }
        let threshold = min(110, max(72, viewport.height * 0.2))
        let upperTrigger = viewport.minY + threshold
        let lowerTrigger = viewport.maxY - threshold

        if fingerY < upperTrigger {
            let proximity = min(1, max(0, (upperTrigger - fingerY) / threshold))
            return -(minimumSpeed + (maximumSpeed - minimumSpeed) * pow(proximity, 1.55))
        }
        if fingerY > lowerTrigger {
            let proximity = min(1, max(0, (fingerY - lowerTrigger) / threshold))
            return minimumSpeed + (maximumSpeed - minimumSpeed) * pow(proximity, 1.55)
        }
        return 0
    }
}

enum ItineraryCardSwipeInteraction {
    static let actionWidth: CGFloat = 68
    static let actionOverlap: CGFloat = 15
    static let actionButtonWidth = actionWidth + actionOverlap
    static let actionCount = 3
    static let actionsWidth: CGFloat = actionWidth * CGFloat(actionCount)

    static func shouldBeginSwipe(
        _ translation: CGSize,
        actionsAlreadyRevealed: Bool,
        dominanceRatio: CGFloat = 1.25,
        minimumHorizontalDistance: CGFloat = 10
    ) -> Bool {
        guard abs(translation.width) >= minimumHorizontalDistance,
              abs(translation.width) > abs(translation.height) * dominanceRatio else { return false }
        return actionsAlreadyRevealed || translation.width < 0
    }

    static func shouldBeginSwipe(
        velocity: CGPoint,
        actionsAlreadyRevealed: Bool,
        touchLocationX: CGFloat? = nil,
        viewWidth: CGFloat? = nil,
        dominanceRatio: CGFloat = 1.25
    ) -> Bool {
        guard abs(velocity.x) > abs(velocity.y) * dominanceRatio else { return false }
        guard actionsAlreadyRevealed || velocity.x < 0 else { return false }
        // 操作按钮已展开时，起点落在按钮色块区域（尾部 actionsWidth）内的
        // 触摸一律让给按钮：否则点按时轻微的横向漂移就会带起平移手势，
        // allowsHitTesting 立即关闭按钮热区，点击被吞（对齐原生
        // swipeActions——从按钮上出发的拖动不用于收起抽屉，收起仍从
        // 卡片本体滑动）。
        if actionsAlreadyRevealed,
           let touchLocationX,
           let viewWidth,
           viewWidth > actionsWidth,
           touchLocationX >= viewWidth - actionsWidth {
            return false
        }
        return true
    }

    static func clampedOffset(baseOffset: CGFloat, translation: CGFloat) -> CGFloat {
        min(0, max(-actionsWidth, baseOffset + translation))
    }

    static func projectedOffset(
        baseOffset: CGFloat,
        translation: CGFloat,
        predictedTranslation: CGFloat
    ) -> CGFloat {
        let currentOffset = clampedOffset(baseOffset: baseOffset, translation: translation)
        let predictionDelta = predictedTranslation - translation
        let maximumProjection = actionWidth * 0.55
        let limitedProjection = min(maximumProjection, max(-maximumProjection, predictionDelta))
        return clampedOffset(baseOffset: currentOffset, translation: limitedProjection)
    }

    static func shouldRevealActions(currentOffset: CGFloat, projectedOffset: CGFloat) -> Bool {
        currentOffset <= -24 && projectedOffset <= -actionsWidth * 0.42
    }

    static func drawerOffset(slotFromTrailing: Int, revealedWidth: CGFloat) -> CGFloat {
        let slot = min(actionCount - 1, max(0, slotFromTrailing))
        let progressOffset = max(0, revealedWidth) * CGFloat(slot) / CGFloat(actionCount)
        return -min(actionWidth * CGFloat(slot), progressOffset)
    }

    static func actionVisibility(revealedWidth: CGFloat) -> CGFloat {
        min(1, max(0, revealedWidth / 24))
    }
}

enum ItineraryLargeImageCardLayout {
    static let outerPadding: CGFloat = 12
    static let contentSpacing: CGFloat = 12
    static let imageAspectRatio: CGFloat = 38 / 21
    static func imageHeight(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - outerPadding * 2) / imageAspectRatio
    }

}

/// 左侧行程时间线轨道的几何常量：轨道列以能放下一档 "09:30" 短时间为准；
/// 卡片列从轨道右侧起排，因此每张卡整体缩窄（轨道宽 + 列间距），左侧留出
/// 轨道空间。spacing 必须与 itineraryDayContent 外层 VStack 的行间距一致，
/// 虚线才能跨过行间接住下一行的轨道。
enum ItineraryCardRailLayout {
    /// 以 24 小时制 "00:00"（14pt 半粗等宽数字）不溢出为准。
    static let width: CGFloat = 44
    static let spacing: CGFloat = 10
}

/// 行程卡左侧的时间线轨道：顶部/底部分别是卡片起始/结束的当地时间，
/// 中部是与卡片垂直居中的类别 icon（机票/酒店/景点，按类别着色），一条
/// 虚线从头贯到底、跨过行间接住下一张卡。时间与 icon 用表面同色小块
/// 遮住穿过的虚线，保持轨道连贯又不叠字。
private struct ItineraryCardRail: View {
    let kind: TravelCardSnapshot.Kind
    let showsConnector: Bool
    let startTime: ItineraryLocalTime.RailTime?
    let endTime: ItineraryLocalTime.RailTime?

    private var tint: Color {
        switch kind {
        case .flight: JourneyPalette.tripBlue
        case .hotel: PrimaryTabPalette.accent
        case .activity: Color(red: 0.32, green: 0.76, blue: 0.47)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            if let startTime {
                railTime(startTime)
            }

            Spacer(minLength: 4)

            Image(systemName: kind == .hotel ? "bed.double.fill" : kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .background(JourneyPalette.listSurface)

            Spacer(minLength: 4)

            if let endTime {
                railTime(endTime)
            }
        }
        .frame(width: ItineraryCardRailLayout.width)
        .background {
            if showsConnector {
                ItineraryRailConnectorShape()
                    .stroke(
                        Color.white.opacity(0.24),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 4.5])
                    )
                    // 行与行之间的 VStack 间距里也要有虚线，才能接住下一行的轨道。
                    .offset(y: ItineraryCardRailLayout.spacing)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    private func railTime(_ time: ItineraryLocalTime.RailTime) -> some View {
        VStack(spacing: 0) {
            Text(time.text)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            if time.showsLocalBadge {
                Text("itinerary.railLocalTimeBadge")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
            }
        }
        .padding(.horizontal, 1)
        .background(JourneyPalette.listSurface)
    }
}

private struct ItineraryRailConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// 上拱的飞行虚线弧线：两端落在 rect 底部两端，顶点朝上，呼应首页地图上
/// 连接两地的飞行轨迹。
private struct ItineraryFlightArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 8, rect.height > 4 else { return path }
        let baseline = rect.maxY - 1
        path.move(to: CGPoint(x: rect.minX + 1, y: baseline))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 1, y: baseline),
            control: CGPoint(x: rect.midX, y: rect.minY + 1)
        )
        return path
    }
}

enum ItineraryFlightCardPresentation {
    /// Compact, locale-independent aviation notation used inside the route arc.
    /// Keeping both units makes card geometry stable as flights change length.
    static func durationText(startAt: Date, endAt: Date?) -> String? {
        guard let endAt else { return nil }
        let minutes = max(0, Int(endAt.timeIntervalSince(startAt) / 60))
        guard minutes > 0, minutes <= 24 * 60 else { return nil }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }
}

/// 行程时间的「当地时间」口径。卡片本身只存绝对时刻（UTC instant），展示层
/// 在这里补齐时区：
/// - 机票：起飞/降落直接用出发/到达机场的时区（`/v1/airports` 返回的 IANA
///   标识，随机场坐标缓存在卡上，见 ``FlightAirportLocationSnapshot/timeZone``）；
/// - 酒店/景点：没有时区数据，用行程内离卡片地点最近的带时区机场近似
///   （300km 内），找不到时退回设备时区。
/// 换算只在展示层进行；按天分组的日历口径（day key）仍用设备时区，两者刻意分开。
enum ItineraryLocalTime {
    /// 左侧轨道一枚起止时间：文本 + 是否需要「当地」标注（时区与设备不同时）。
    struct RailTime: Equatable {
        let text: String
        let showsLocalBadge: Bool
    }

    static let deviceTimeZone: TimeZone = .autoupdatingCurrent

    // MARK: 时区解析

    /// 时刻所属时区：机票起飞用出发机场时区；其余暂按设备时区（列表页的
    /// 非机票卡请改用 `timeZoneByCardID` 的推导结果）。
    static func startTimeZone(for card: TravelCardSnapshot) -> TimeZone {
        if card.kind == .flight,
           let timeZone = card.fromAirportLocation?.timeZone.flatMap({ TimeZone(identifier: $0) }) {
            return timeZone
        }
        return deviceTimeZone
    }

    /// 时刻所属时区：机票降落用到达机场时区；其余暂按设备时区。
    static func endTimeZone(for card: TravelCardSnapshot) -> TimeZone {
        if card.kind == .flight,
           let timeZone = card.toAirportLocation?.timeZone.flatMap({ TimeZone(identifier: $0) }) {
            return timeZone
        }
        return deviceTimeZone
    }

    /// 非机票卡的近似当地时间表：每张卡取行程内最近的带时区机场。
    /// 在列表页按数据变化算一次后逐层下发，避免每张卡都重扫全部航班。
    static func timeZoneByCardID(in days: [TripDaySnapshot]) -> [UUID: TimeZone] {
        var result: [UUID: TimeZone] = [:]
        for day in days {
            for card in day.cards where card.kind != .flight {
                if let timeZone = nearestAirportTimeZone(for: card, in: days) {
                    result[card.id] = timeZone
                }
            }
        }
        return result
    }

    /// 离卡片地点最近的带时区机场（行程内已解析的起降机场都参与）。超过
    /// 300km 视为不在同一片区域，宁缺毋滥返回 nil。
    static func nearestAirportTimeZone(
        for card: TravelCardSnapshot,
        in days: [TripDaySnapshot]
    ) -> TimeZone? {
        guard let latitude = card.place?.latitude,
              let longitude = card.place?.longitude else { return nil }
        var best: (distanceMeters: Double, timeZone: TimeZone)?
        for other in days.flatMap(\.cards) {
            for location in [other.fromAirportLocation, other.toAirportLocation].compactMap({ $0 }) {
                guard location.hasValidCoordinate,
                      let timeZone = location.timeZone.flatMap({ TimeZone(identifier: $0) }) else { continue }
                let distance = distanceMeters(
                    fromLatitude: latitude,
                    longitude: longitude,
                    toLatitude: location.latitude,
                    toLongitude: location.longitude
                )
                if distance <= 300_000, best == nil || distance < best!.distanceMeters {
                    best = (distance, timeZone)
                }
            }
        }
        return best?.timeZone
    }

    static func isDistinctFromDevice(_ timeZone: TimeZone) -> Bool {
        timeZone.identifier != deviceTimeZone.identifier
    }

    // MARK: 轨道起止时间

    /// 轨道顶部：起始当地时间。酒店用入住政策时间（本来就是当地时间字符串）。
    static func railStartTime(
        for card: TravelCardSnapshot,
        timeZone: TimeZone? = nil
    ) -> RailTime? {
        switch card.kind {
        case .hotel:
            guard let text = card.checkInTime?.nilIfEmpty else { return nil }
            return RailTime(text: text, showsLocalBadge: timeZone.map(isDistinctFromDevice) ?? false)
        case .flight, .activity:
            let effective = card.kind == .flight
                ? startTimeZone(for: card)
                : (timeZone ?? deviceTimeZone)
            return railTime(card.startAt, in: effective)
        }
    }

    /// 轨道底部：结束当地时间。酒店用退房政策时间；机票按到达机场时区；
    /// 景点卡会把到下一站的交通耗时计算进去——底部时间显示「最晚出发
    /// 时刻」，即结束时刻与（下一站开始 − 交通耗时）的较早者，让相邻卡
    /// 的时间经交通衔接。没有可用时刻就不展示。
    static func railEndTime(
        for card: TravelCardSnapshot,
        nextCard: TravelCardSnapshot? = nil,
        transitSeconds: Int? = nil,
        timeZone: TimeZone? = nil
    ) -> RailTime? {
        switch card.kind {
        case .hotel:
            guard let text = card.checkOutTime?.nilIfEmpty else { return nil }
            return RailTime(text: text, showsLocalBadge: timeZone.map(isDistinctFromDevice) ?? false)
        case .flight:
            guard let endAt = card.endAt else { return nil }
            return railTime(endAt, in: endTimeZone(for: card))
        case .activity:
            var endAt = card.endAt
            if let transitSeconds, transitSeconds > 0, let nextCard {
                let leaveBy = nextCard.startAt.addingTimeInterval(-Double(transitSeconds))
                endAt = endAt.map { min($0, leaveBy) } ?? leaveBy
            }
            guard let endAt, endAt > card.startAt else { return nil }
            return railTime(endAt, in: timeZone ?? deviceTimeZone)
        }
    }

    private static func railTime(_ date: Date, in timeZone: TimeZone) -> RailTime {
        RailTime(
            text: railTimeText(date, in: timeZone),
            showsLocalBadge: isDistinctFromDevice(timeZone)
        )
    }

    // MARK: 格式化（按 IANA 标识缓存 DateFormatter）

    private static let formatterLock = NSLock()
    private static var cachedTimeFormatters: [String: DateFormatter] = [:]
    private static var cachedDateFormatters: [String: DateFormatter] = [:]
    private static var cachedRailTimeFormatters: [String: DateFormatter] = [:]

    /// 轨道时间固定 24 小时制（HH:mm），不受系统 12/24 小时设置影响，
    /// 保证轨道时间宽度稳定不溢出。
    static func railTimeText(_ date: Date, in timeZone: TimeZone) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = cachedRailTimeFormatters[timeZone.identifier] {
            return cached.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        cachedRailTimeFormatters[timeZone.identifier] = formatter
        return formatter.string(from: date)
    }

    /// HH:mm（随系统语言），按指定时区。与卡内时刻同款式，只是换了时区。
    static func shortTime(_ date: Date, in timeZone: TimeZone) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = cachedTimeFormatters[timeZone.identifier] {
            return cached.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = timeZone
        cachedTimeFormatters[timeZone.identifier] = formatter
        return formatter.string(from: date)
    }

    /// 月日（MMMd），按指定时区。
    static func monthDay(_ date: Date, in timeZone: TimeZone) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = cachedDateFormatters[timeZone.identifier] {
            return cached.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        formatter.timeZone = timeZone
        cachedDateFormatters[timeZone.identifier] = formatter
        return formatter.string(from: date)
    }

    private static func distanceMeters(
        fromLatitude: Double,
        longitude fromLongitude: Double,
        toLatitude: Double,
        toLongitude: Double
    ) -> Double {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        let radius = 6_371_000.0
        let phi = radians(fromLatitude)
        let otherPhi = radians(toLatitude)
        let deltaPhi = radians(toLatitude - fromLatitude)
        let deltaLambda = radians(toLongitude - fromLongitude)
        let haversine = pow(sin(deltaPhi / 2), 2)
            + cos(phi) * cos(otherPhi) * pow(sin(deltaLambda / 2), 2)
        return 2 * radius * asin(min(1, sqrt(haversine)))
    }
}

enum ItineraryCardDragPolicy {
    /// 长按拖动排序对所有卡片类别开放（此前仅景点卡）。跨天卡的投影
    /// 片段支持左滑操作，但拖动排序仍从源日的那张卡发起。
    static func allowsLongPressDrag(_ card: TravelCardSnapshot) -> Bool {
        switch card.kind {
        case .flight, .hotel, .activity: true
        }
    }
}

enum ItineraryListPresentation {
    struct HotelNightProgress: Equatable {
        let nightIndex: Int
        let totalNights: Int
    }

    struct MultiDayProgress: Equatable {
        let dayIndex: Int
        let totalDays: Int
    }

    enum CardProgress: Equatable {
        case hotelNight(HotelNightProgress)
        case day(MultiDayProgress)
    }

    struct HotelNightOccurrence: Identifiable, Equatable {
        let card: TravelCardSnapshot
        let dayDate: String
        let progress: HotelNightProgress

        var id: String { "\(card.id.uuidString)-\(dayDate)" }
    }

    struct ProjectedCardOccurrence: Identifiable, Equatable {
        let card: TravelCardSnapshot
        let dayDate: String
        let progress: CardProgress

        var id: String { "\(card.id.uuidString)-\(dayDate)" }
        var isHotelNight: Bool {
            if case .hotelNight = progress { return true }
            return false
        }
    }

    private static let weekdaySymbols = [
        String(localized: "common.weekday.0"),
        String(localized: "common.weekday.1"),
        String(localized: "common.weekday.2"),
        String(localized: "common.weekday.3"),
        String(localized: "common.weekday.4"),
        String(localized: "common.weekday.5"),
        String(localized: "common.weekday.6")
    ]

    static func selectedIndex(date: String?, in days: [TripDaySnapshot]) -> Int {
        guard !days.isEmpty else { return 0 }
        return date.flatMap { selected in days.firstIndex(where: { $0.date == selected }) } ?? 0
    }

    static func todayIndex(in days: [TripDaySnapshot], today: Date = .now) -> Int {
        guard !days.isEmpty else { return 0 }
        let todayString = dayFormatter.string(from: today)
        if let exact = days.firstIndex(where: { $0.date == todayString }) { return exact }
        guard let todayDate = parseDayKey(todayString) else { return 0 }
        return days.enumerated().min { left, right in
            abs((parseDayKey(left.element.date) ?? .distantPast).timeIntervalSince(todayDate))
                < abs((parseDayKey(right.element.date) ?? .distantPast).timeIntervalSince(todayDate))
        }?.offset ?? 0
    }

    static func timelineLabel(_ day: TripDaySnapshot, _ isToday: Bool) -> String {
        guard let date = parseDayKey(day.date) else { return day.date }
        let weekday = weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return isToday
            ? String(format: String(localized: "common.timelineToday"), weekday)
            : String(format: String(localized: "common.timelineDate"), numericFormatter.string(from: date), weekday)
    }

    static func monthDay(for day: TripDaySnapshot) -> String {
        guard let date = parseDayKey(day.date) else { return day.date }
        return numericFormatter.string(from: date)
    }

    static func weekday(for day: TripDaySnapshot) -> String {
        guard let date = parseDayKey(day.date) else { return "" }
        return weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }

    /// Builds an end-of-day city timeline. A flight arrival or a local POI on
    /// a day advances the current city; empty days inherit the previous city.
    /// Reverse-geocoded values fill gaps where persisted places only contain
    /// coordinates and an address that cannot be safely parsed.
    static func cityLabels(
        in days: [TripDaySnapshot],
        resolvedCityByDate: [String: String] = [:],
        fallbackDestination: String? = nil
    ) -> [String: String] {
        let sortedDays = days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
        var explicitByDate: [String: String] = [:]
        for day in sortedDays {
            if let city = immediateCity(for: day)
                ?? normalizedCity(resolvedCityByDate[day.date]) {
                explicitByDate[day.date] = city
            }
        }

        let firstKnownCity = sortedDays.lazy.compactMap { explicitByDate[$0.date] }.first
        var currentCity = firstKnownCity ?? normalizedCity(fallbackDestination)
        var result: [String: String] = [:]
        for day in sortedDays {
            if let explicit = explicitByDate[day.date] {
                currentCity = explicit
            }
            if let currentCity {
                result[day.date] = currentCity
            }
        }
        return result
    }

    static func cityResolutionKey(for days: [TripDaySnapshot]) -> String {
        days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
            .map { day in
                let cards = orderedCards(day.cards).map { card in
                    let point = card.place?.point
                    return [
                        card.id.uuidString,
                        String(card.updatedAt.timeIntervalSince1970),
                        point.map { "\($0.latitude),\($0.longitude)" } ?? "",
                        card.toAirportLocation?.city ?? "",
                    ].joined(separator: "|")
                }
                return "\(day.date):\(cards.joined(separator: ";"))"
            }
            .joined(separator: "/")
    }

    static func flightAirportResolutionKey(for days: [TripDaySnapshot]) -> String {
        days
            .flatMap(\.cards)
            .filter { $0.kind == .flight }
            .map { card in
                [
                    card.serverID.map(String.init) ?? card.id.uuidString,
                    card.fromAirport ?? "",
                    card.toAirport ?? "",
                ].joined(separator: "|")
            }
            .joined(separator: ";")
    }

    /// Two consecutive located POIs with a flight departing between them are
    /// connected by that flight alone: its arc replaces the ground leg on the
    /// map, and the list shows no leg estimate for the pair. The returned IDs
    /// are the origins of exactly those POI pairs, keyed the same way as the
    /// map points built from `pois`.
    static func flownLegOriginIDs(
        pois: [TravelCardSnapshot],
        flights: [TravelCardSnapshot]
    ) -> Set<UUID> {
        guard !flights.isEmpty else { return [] }
        let departureTimes = flights.map(\.startAt)
        let locatedPOIs = pois.filter { $0.place?.point != nil }
        guard locatedPOIs.count > 1 else { return [] }

        var originIDs: Set<UUID> = []
        for (origin, destination) in zip(locatedPOIs, locatedPOIs.dropFirst()) {
            if departureTimes.contains(where: { $0 >= origin.startAt && $0 <= destination.startAt }) {
                originIDs.insert(origin.id)
            }
        }
        return originIDs
    }

    /// Point where travel continues after a card. Flights end at their arrival
    /// airport; ordinary cards continue to use their verified POI coordinate.
    static func legOriginPoint(for card: TravelCardSnapshot) -> RoutePoint? {
        if card.kind == .flight,
           let airport = card.toAirportLocation,
           airport.hasValidCoordinate {
            return RoutePoint(latitude: airport.latitude, longitude: airport.longitude)
        }
        return card.place?.point
    }

    /// Point where travel must reach before a card starts. Flights begin at
    /// their departure airport; ordinary cards use their verified POI.
    static func legDestinationPoint(for card: TravelCardSnapshot) -> RoutePoint? {
        if card.kind == .flight,
           let airport = card.fromAirportLocation,
           airport.hasValidCoordinate {
            return RoutePoint(latitude: airport.latitude, longitude: airport.longitude)
        }
        return card.place?.point
    }

    static func immediateCity(for day: TripDaySnapshot) -> String? {
        var current: String?
        for card in orderedCards(day.cards) {
            if card.kind == .flight {
                if let arrivalCity = normalizedCity(card.toAirportLocation?.city) {
                    current = arrivalCity
                }
                continue
            }
            if let city = cityFromAddress(card.place?.address) {
                current = city
            }
        }
        return current
    }

    static func cityFromAddress(_ address: String?) -> String? {
        guard var value = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        // Remove a province-level prefix before looking for a city-level
        // suffix, e.g. “云南省丽江市古城区” -> “丽江”.
        for marker in ["自治区", "省"] {
            if let range = value.range(of: marker, options: .backwards) {
                value = String(value[range.upperBound...])
                break
            }
        }
        for suffix in ["特别行政区", "自治州", "地区", "市", "都", "府"] {
            guard let range = value.range(of: suffix) else { continue }
            let city = String(value[..<range.upperBound])
            if let normalized = normalizedCity(city), normalized.count >= 2 {
                return normalized
            }
        }

        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsStreetDetail = compact.rangeOfCharacter(from: .decimalDigits) != nil
            || compact.contains("区") || compact.contains("县")
            || compact.contains(",") || compact.contains("，")
        guard !containsStreetDetail, compact.count <= 16 else { return nil }
        return normalizedCity(compact)
    }

    static func normalizedCity(_ value: String?) -> String? {
        guard var city = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty else { return nil }
        for suffix in ["特别行政区", "自治州", "地区"] where city.hasSuffix(suffix) {
            city.removeLast(suffix.count)
        }
        if city.count > 2, let suffix = city.last, ["市", "都", "府"].contains(String(suffix)) {
            city.removeLast()
        }
        return city.isEmpty ? nil : city
    }

    static func daySummary(for day: TripDaySnapshot) -> String {
        daySummary(for: orderedCards(day.cards))
    }

    static func daySummary(
        for day: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let projectedCards = projectedMultiDayCards(for: day, in: days, timeZone: timeZone).map(\.card)
        return daySummary(for: orderedCards(day.cards) + projectedCards)
    }

    private static func daySummary(for cards: [TravelCardSnapshot]) -> String {
        let titles = cards
            .prefix(2)
            .map { ($0.place?.name.nilIfEmpty ?? $0.title).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return String(localized: "itinerary.daySummaryEmpty") }
        return String(titles.joined(separator: String(localized: "lottery.contextSeparator")).prefix(8))
    }

    static func hotelNightProgress(
        for card: TravelCardSnapshot,
        on targetDay: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> HotelNightProgress? {
        guard let sourceDay = days.first(where: { day in
            day.cards.contains(where: { $0.id == card.id })
        }) else { return nil }
        return hotelNightProgress(
            for: card,
            sourceDay: sourceDay,
            targetDay: targetDay,
            timeZone: timeZone
        )
    }

    static func hotelNightProgress(
        for card: TravelCardSnapshot,
        sourceDay: TripDaySnapshot,
        targetDay: TripDaySnapshot,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> HotelNightProgress? {
        guard card.kind == .hotel,
              let checkoutAt = card.endAt,
              let sourceDate = parseDayKey(sourceDay.date),
              let targetDate = parseDayKey(targetDay.date),
              let checkoutDate = utcDayKey(for: checkoutAt, in: timeZone),
              sourceDate <= targetDate,
              targetDate < checkoutDate,
              let totalNights = calendar.dateComponents(
                  [.day],
                  from: sourceDate,
                  to: checkoutDate
              ).day,
              totalNights > 1,
              let elapsedNights = calendar.dateComponents(
                  [.day],
                  from: sourceDate,
                  to: targetDate
              ).day else { return nil }

        return HotelNightProgress(
            nightIndex: elapsedNights + 1,
            totalNights: totalNights
        )
    }

    static func projectedHotelNights(
        for targetDay: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [HotelNightOccurrence] {
        projectedMultiDayCards(for: targetDay, in: days, timeZone: timeZone).compactMap { occurrence in
            guard case .hotelNight(let progress) = occurrence.progress else { return nil }
            return HotelNightOccurrence(
                card: occurrence.card,
                dayDate: occurrence.dayDate,
                progress: progress
            )
        }
    }

    static func multiDayProgress(
        for card: TravelCardSnapshot,
        on targetDay: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> MultiDayProgress? {
        guard let sourceDay = days.first(where: { day in
            day.cards.contains(where: { $0.id == card.id })
        }) else { return nil }
        return multiDayProgress(
            for: card,
            sourceDay: sourceDay,
            targetDay: targetDay,
            timeZone: timeZone
        )
    }

    static func multiDayProgress(
        for card: TravelCardSnapshot,
        sourceDay: TripDaySnapshot,
        targetDay: TripDaySnapshot,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> MultiDayProgress? {
        guard card.kind != .hotel,
              let endAt = card.endAt,
              let sourceDate = parseDayKey(sourceDay.date),
              let targetDate = parseDayKey(targetDay.date),
              let endDate = utcDayKey(for: endAt, in: timeZone),
              sourceDate <= targetDate,
              targetDate <= endDate,
              let elapsedDays = calendar.dateComponents(
                  [.day],
                  from: sourceDate,
                  to: targetDate
              ).day,
              let daySpan = calendar.dateComponents(
                  [.day],
                  from: sourceDate,
                  to: endDate
              ).day,
              daySpan > 0 else { return nil }

        return MultiDayProgress(
            dayIndex: elapsedDays + 1,
            totalDays: daySpan + 1
        )
    }

    static func cardProgress(
        for card: TravelCardSnapshot,
        on targetDay: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> CardProgress? {
        guard let sourceDay = days.first(where: { day in
            day.cards.contains(where: { $0.id == card.id })
        }) else { return nil }
        return cardProgress(
            for: card,
            sourceDay: sourceDay,
            targetDay: targetDay,
            timeZone: timeZone
        )
    }

    static func cardProgress(
        for card: TravelCardSnapshot,
        sourceDay: TripDaySnapshot,
        targetDay: TripDaySnapshot,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> CardProgress? {
        if let hotel = hotelNightProgress(
            for: card,
            sourceDay: sourceDay,
            targetDay: targetDay,
            timeZone: timeZone
        ) {
            return .hotelNight(hotel)
        }
        if let day = multiDayProgress(
            for: card,
            sourceDay: sourceDay,
            targetDay: targetDay,
            timeZone: timeZone
        ) {
            return .day(day)
        }
        return nil
    }

    static func progressLabel(_ progress: CardProgress?) -> String? {
        guard let progress else { return nil }
        switch progress {
        case .hotelNight(let progress):
            return String(
                format: String(localized: "itinerary.hotelNightProgress"),
                progress.nightIndex,
                progress.totalNights
            )
        case .day(let progress):
            return String(
                format: String(localized: "itinerary.multiDayProgress"),
                progress.dayIndex,
                progress.totalDays
            )
        }
    }

    /// Projects one persisted card into every itinerary day it occupies. A
    /// hotel occupies nights and excludes checkout day; all other card kinds
    /// include their end date. The projection is display-only and keeps the
    /// original card identity so edits remain single-source.
    static func projectedMultiDayCards(
        for targetDay: TripDaySnapshot,
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [ProjectedCardOccurrence] {
        projectedMultiDayCardsByDay(in: days, timeZone: timeZone)[targetDay.id] ?? []
    }

    /// The same projection for every day at once, keyed by target day ID. The
    /// list used to recompute the per-day variant inside every day section's
    /// body, re-running the card-vs-day matrix each time a section rendered —
    /// the other half of the scroll-time runloop hang.
    static func projectedMultiDayCardsByDay(
        in days: [TripDaySnapshot],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [UUID: [ProjectedCardOccurrence]] {
        var byDay: [UUID: [ProjectedCardOccurrence]] = [:]
        for sourceDay in days {
            for card in orderedCards(sourceDay.cards) {
                for targetDay in days where targetDay.id != sourceDay.id {
                    guard let progress = cardProgress(
                        for: card,
                        sourceDay: sourceDay,
                        targetDay: targetDay,
                        timeZone: timeZone
                    ) else { continue }

                    switch progress {
                    case .hotelNight(let value) where value.nightIndex > 1:
                        byDay[targetDay.id, default: []].append(
                            ProjectedCardOccurrence(
                                card: card,
                                dayDate: targetDay.date,
                                progress: progress
                            )
                        )
                    case .day(let value) where value.dayIndex > 1:
                        byDay[targetDay.id, default: []].append(
                            ProjectedCardOccurrence(
                                card: card,
                                dayDate: targetDay.date,
                                progress: progress
                            )
                        )
                    default:
                        continue
                    }
                }
            }
        }
        return byDay
    }

    static func orderedCards(_ cards: [TravelCardSnapshot]) -> [TravelCardSnapshot] {
        cards.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    struct DayListItem: Identifiable {
        let id: String
        let card: TravelCardSnapshot
        let progress: CardProgress?
        let ownIndex: Int?
        let effectiveStart: Date?

        var isHotelNight: Bool {
            guard let progress else { return false }
            if case .hotelNight = progress { return true }
            return false
        }
    }

    /// Merges a day's own cards with the multi-day occurrences projected from
    /// other days into one chronological list. A projected card's effective
    /// start on the target day is the later of its real start and the day's
    /// local midnight, so an overnight flight landing 00:15 sorts before an
    /// 08:00 departure instead of trailing the whole day. Hotel-night
    /// projections have no daytime slot and stay pinned to the bottom, like
    /// the night's lodging. Own cards keep their relative order untouched so
    /// manual reordering keeps working.
    static func mergedDayListItems(
        ownCards: [TravelCardSnapshot],
        projectedOccurrences: [ProjectedCardOccurrence],
        day: TripDaySnapshot,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [DayListItem] {
        let dayStart = localDayStart(day.date, timeZone: timeZone)
        let ownItems = ownCards.enumerated().map { index, card in
            DayListItem(
                id: card.id.uuidString,
                card: card,
                progress: nil,
                ownIndex: index,
                effectiveStart: card.startAt
            )
        }
        var timedProjections = projectedOccurrences.filter { !$0.isHotelNight }.map { occurrence in
            DayListItem(
                id: occurrence.id,
                card: occurrence.card,
                progress: occurrence.progress,
                ownIndex: nil,
                effectiveStart: max(
                    occurrence.card.startAt,
                    dayStart ?? occurrence.card.startAt
                )
            )
        }

        var merged: [DayListItem] = []
        merged.reserveCapacity(ownItems.count + timedProjections.count)
        for ownItem in ownItems {
            guard let ownStart = ownItem.effectiveStart else { continue }
            while let first = timedProjections.first,
                  let firstStart = first.effectiveStart,
                  firstStart < ownStart {
                merged.append(first)
                timedProjections.removeFirst()
            }
            merged.append(ownItem)
        }
        merged.append(contentsOf: timedProjections)
        merged.append(
            contentsOf: projectedOccurrences.filter(\.isHotelNight).map { occurrence in
                DayListItem(
                    id: occurrence.id,
                    card: occurrence.card,
                    progress: occurrence.progress,
                    ownIndex: nil,
                    effectiveStart: nil
                )
            }
        )
        return merged
    }

    static func localDayStart(
        _ dateString: String,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        guard let components = dayComponents(fromDateString: dateString) else { return nil }
        let calendar = localDayCalendar(for: timeZone)
        guard let date = calendar.date(from: components) else { return nil }
        // Reject rollover input such as "2026-02-31": the strict POSIX ICU
        // parse this replaces returned nil for those.
        let roundtrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundtrip.year == components.year,
              roundtrip.month == components.month,
              roundtrip.day == components.day else { return nil }
        return date
    }

    static func movingCard(_ cardID: UUID, onto targetID: UUID, in orderedIDs: [UUID]) -> [UUID] {
        guard cardID != targetID,
              let targetIndex = orderedIDs.firstIndex(of: targetID) else { return orderedIDs }

        return movingCard(cardID, to: targetIndex, in: orderedIDs)
    }

    static func movingCard(_ cardID: UUID, to destinationIndex: Int, in orderedIDs: [UUID]) -> [UUID] {
        guard let sourceIndex = orderedIDs.firstIndex(of: cardID),
              orderedIDs.indices.contains(destinationIndex) else { return orderedIDs }

        var result = orderedIDs
        let movedID = result.remove(at: sourceIndex)
        result.insert(movedID, at: min(destinationIndex, result.count))
        return result
    }

    /// 卡片起止时间区间，按传入时区格式化（列表页传卡片当地时间）。
    static func timeRange(
        for card: TravelCardSnapshot,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let start = ItineraryLocalTime.shortTime(card.startAt, in: timeZone)
        guard let endAt = card.endAt else { return start }
        return String(
            format: String(localized: "itinerary.cardTimeRange"),
            start,
            ItineraryLocalTime.shortTime(endAt, in: timeZone)
        )
    }

    static func currentOrNextCardID(
        in days: [TripDaySnapshot],
        now: Date
    ) -> UUID? {
        let cards = days
            .flatMap(\.cards)
            .sorted {
                if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        guard !cards.isEmpty else { return nil }

        for index in cards.indices.reversed() where cards[index].startAt <= now {
            let defaultEnd = cards[index].startAt.addingTimeInterval(2 * 60 * 60)
            let nextStart = cards.indices.contains(index + 1) ? cards[index + 1].startAt : nil
            let inferredEnd = nextStart.map { min(defaultEnd, $0) } ?? defaultEnd
            let effectiveEnd = cards[index].endAt ?? inferredEnd
            if now < effectiveEnd { return cards[index].id }
        }
        return cards.first(where: { $0.startAt > now })?.id
    }

    static func cardSummary(for card: TravelCardSnapshot) -> String? {
        guard card.kind != .flight else { return nil }
        for candidate in [card.description, card.notes] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        let tips = card.tips?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return tips?.isEmpty == false ? tips?.joined(separator: " · ") : nil
    }

    static func agentPrompt(for card: TravelCardSnapshot, date: String) -> String {
        var context = [
            String(format: String(localized: "itinerary.agentDate"), date),
            String(format: String(localized: "itinerary.agentCard"), card.title),
            String(format: String(localized: "itinerary.agentTime"), timeRange(for: card))
        ]
        if let place = card.place?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !place.isEmpty {
            context.append(String(format: String(localized: "itinerary.agentPlace"), place))
        }
        return String(localized: "itinerary.agentPrefix") + context.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // Day-key conversions used to allocate a fresh `DateFormatter` (plus ICU
    // symbol setup) on every call, and the list calls them per card per day
    // per render — a scroll-time runloop hang pinned the whole cost on this.
    // Calendar math with cached calendars and a memoized day-string parse
    // keeps the same results without ICU in the loop.

    private static let gmtDayKeyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let dayKeyLock = NSLock()
    // Both statics are only touched inside dayKeyLock-held regions.
    nonisolated(unsafe) private static var dayKeyCalendars: [String: Calendar] = [:]
    nonisolated(unsafe) private static var parsedDayKeys: [String: Date?] = [:]

    private static func localDayCalendar(for timeZone: TimeZone) -> Calendar {
        dayKeyLock.lock()
        defer { dayKeyLock.unlock() }
        if let cached = dayKeyCalendars[timeZone.identifier] { return cached }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        dayKeyCalendars[timeZone.identifier] = calendar
        return calendar
    }

    /// UTC-midnight `Date` for a `yyyy-MM-dd` string, matching `dayFormatter`
    /// semantics. Results are memoized because the same day strings are
    /// parsed over and over while the list renders.
    static func parseDayKey(_ dateString: String) -> Date? {
        dayKeyLock.lock()
        if let cached = parsedDayKeys[dateString] {
            dayKeyLock.unlock()
            return cached
        }
        dayKeyLock.unlock()

        let parsed: Date?
        if let components = dayComponents(fromDateString: dateString),
           let date = gmtDayKeyCalendar.date(from: components) {
            let roundtrip = gmtDayKeyCalendar.dateComponents([.year, .month, .day], from: date)
            parsed = roundtrip.year == components.year
                && roundtrip.month == components.month
                && roundtrip.day == components.day
                ? date
                : nil
        } else {
            parsed = nil
        }

        dayKeyLock.lock()
        parsedDayKeys[dateString] = parsed
        dayKeyLock.unlock()
        return parsed
    }

    /// UTC-midnight `Date` for the local calendar day containing `date`,
    /// replacing the old `dayFormatter.date(from: localDayString(...))`
    /// round trip through two formatters.
    private static func utcDayKey(for date: Date, in timeZone: TimeZone) -> Date? {
        let components = localDayCalendar(for: timeZone)
            .dateComponents([.year, .month, .day], from: date)
        return gmtDayKeyCalendar.date(from: components)
    }

    private static func dayComponents(fromDateString dateString: String) -> DateComponents? {
        let parts = dateString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), (0...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private static let numericFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM.dd"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

@MainActor
private enum ItineraryDayCityResolver {
    static func resolveCities(for days: [TripDaySnapshot]) async -> [String: String] {
        var resolved: [String: String] = [:]
        for day in days.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
            guard !Task.isCancelled,
                  ItineraryListPresentation.immediateCity(for: day) == nil,
                  let point = representativePoint(for: day) else { continue }
            guard let request = MKReverseGeocodingRequest(
                location: CLLocation(latitude: point.latitude, longitude: point.longitude)
            ) else { continue }
            request.preferredLocale = .autoupdatingCurrent
            do {
                let mapItems = try await request.mapItems
                guard !Task.isCancelled, let mapItem = mapItems.first else { continue }
                let city = mapItem.addressRepresentations?.cityName
                    ?? mapItem.addressRepresentations?.cityWithContext
                if let city = ItineraryListPresentation.normalizedCity(city) {
                    resolved[day.date] = city
                }
            } catch {
                continue
            }
        }
        return resolved
    }

    private static func representativePoint(for day: TripDaySnapshot) -> RoutePoint? {
        let cards = ItineraryListPresentation.orderedCards(day.cards)
        if let arrival = cards.reversed().compactMap(\.toAirportLocation).first(where: \.hasValidCoordinate) {
            return RoutePoint(latitude: arrival.latitude, longitude: arrival.longitude)
        }
        return cards.lazy.compactMap(\.place?.point).first
    }
}

private extension View {
    func journeyRoundControl() -> some View {
        self
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(JourneyPalette.controlFill, in: Circle())
            .buttonStyle(.plain)
    }

    func itineraryHeaderButtonStyle() -> some View {
        self
            .foregroundStyle(.white)
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
            .buttonStyle(.plain)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
