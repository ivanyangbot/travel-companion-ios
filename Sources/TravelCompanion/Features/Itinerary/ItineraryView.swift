import AuthenticationServices
import SwiftUI
import UIKit

struct ItineraryView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var sharedLinkStore: PendingSharedLinkStore
    @ObservedObject var appleSignIn: AppleSignInStore
    @Binding var section: JourneyView.Section
    @State private var activeDaySheet: DaySheet?
    @State private var showsTripEditor = false
    @State private var showsNewTripEditor = false
    @State private var showsSignOutConfirmation = false
    @State private var agentSheet: ItineraryAgentSheet?
    @State private var dayPendingDeletion: TripDaySnapshot?
    @State private var activeCardEditor: CardEditorTarget?
    @State private var detailCard: TravelCardSnapshot?
    @State private var cardPendingDeletion: TravelCardSnapshot?
    @State private var expenseEditorDate: Date?
    @State private var showsSharingSheet = false
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
    @State private var itineraryCardFrames: [UUID: CGRect] = [:]
    @State private var itineraryDayFrames: [UUID: CGRect] = [:]
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
    @StateObject private var itineraryListScrollController = ItineraryListScrollController()
    @StateObject private var linkHandler = ExternalLinkHandler()

    var body: some View {
        NavigationStack {
            alertContent
            .alert("itinerary.deleteDayTitle", isPresented: Binding(
                get: { dayPendingDeletion != nil },
                set: { if !$0 { dayPendingDeletion = nil } }
            ), presenting: dayPendingDeletion) { day in
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
            .alert("settings.signOutFailedTitle", isPresented: Binding(
                get: { signOutErrorMessage != nil },
                set: { if !$0 { signOutErrorMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { signOutErrorMessage = nil }
            } message: {
                Text(signOutErrorMessage ?? "")
            }
            .alert("itinerary.deleteCardTitle", isPresented: Binding(
                get: { cardPendingDeletion != nil },
                set: { if !$0 { cardPendingDeletion = nil } }
            ), presenting: cardPendingDeletion) { card in
                Button("common.delete", role: .destructive) {
                    Task { await syncEngine.deleteCard(card) }
                    cardPendingDeletion = nil
                }
                Button("common.cancel", role: .cancel) { cardPendingDeletion = nil }
            } message: { _ in
                Text("itinerary.deleteCardMessage")
            }
            .alert("common.cannotOpenLink", isPresented: Binding(
                get: { linkHandler.alertMessage != nil },
                set: { if !$0 { linkHandler.alertMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { linkHandler.alertMessage = nil }
            } message: {
                Text(linkHandler.alertMessage ?? "")
            }
            .onChange(of: sharedLinkStore.pendingInviteToken) { _, token in
                guard token != nil else { return }
                joinPendingInviteIfPossible()
            }
            .sheet(isPresented: $showsSharingSheet) {
                TripSharingSheet(syncEngine: syncEngine)
            }
            .task {
                joinPendingInviteIfPossible()
            }
            .onChange(of: syncEngine.isUserAuthenticated) { _, isAuthenticated in
                guard isAuthenticated else { return }
                joinPendingInviteIfPossible()
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
            .sheet(isPresented: $showsTripEditor) {
                if let trip = syncEngine.trip {
                    TripSetupSheet(initialTrip: trip) { destination, startDate, endDate, currency in
                        Task { await syncEngine.saveSetup(destination: destination, startDate: startDate, endDate: endDate, currency: currency) }
                    }
                }
            }
            .sheet(isPresented: $showsNewTripEditor) {
                TripSetupSheet(isNewTrip: true) { destination, startDate, endDate, currency in
                    showsNewTripEditor = false
                    Task { await syncEngine.createTrip(destination: destination, startDate: startDate, endDate: endDate, currency: currency) }
                }
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
                CardDetailView(card: card, currency: syncEngine.trip?.currency)
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
            .sheet(isPresented: Binding(
                get: { expenseEditorDate != nil },
                set: { if !$0 { expenseEditorDate = nil } }
            )) {
                if let trip = syncEngine.trip, let date = expenseEditorDate {
                    ExpenseEditorView(trip: trip, initialDate: date) { request in
                        Task { await syncEngine.addExpense(request) }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { linkHandler.browserURL != nil },
                set: { if !$0 { linkHandler.browserURL = nil } }
            )) {
                if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
            }
    }

    @ViewBuilder
    private var itineraryContent: some View {
        if let trip = syncEngine.trip {
            if trip.isConfigured {
                detailedItinerary(trip)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        journeyActionBar
                        TripSetupSheet { destination, startDate, endDate, currency in
                            Task { await syncEngine.saveSetup(destination: destination, startDate: startDate, endDate: endDate, currency: currency) }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 112)
                }
                .scrollIndicators(.hidden)
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
            ScrollView {
                TripSetupSheet(isNewTrip: true) { destination, startDate, endDate, currency in
                    Task {
                        await syncEngine.createTrip(
                            destination: destination,
                            startDate: startDate,
                            endDate: endDate,
                            currency: currency
                        )
                    }
                }
                .padding()
            }
        } else if case .localOnly = syncEngine.status {
            ScrollView {
                VStack(spacing: 16) {
                    signInBanner
                    TripSetupSheet(isNewTrip: true) { destination, startDate, endDate, currency in
                        Task { await syncEngine.createTrip(destination: destination, startDate: startDate, endDate: endDate, currency: currency) }
                    }
                }
                .padding()
            }
        } else {
            ProgressView("today.openingSharedTrip")
        }
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
                while !Task.isCancelled {
                    itineraryNow = .now
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
        if let draggedListCard,
           let day = days.first(where: { $0.id == draggedListCard.dayID }),
           let card = day.cards.first(where: { $0.id == draggedListCard.cardID }),
           let startFrame = draggedListCardStartFrame {
            let index = orderedListCards(for: day).firstIndex(where: { $0.id == card.id }) ?? 0
            itineraryCompactCardContent(
                card,
                index: index,
                showsTimeAccent: isCurrentOrNext(card, in: days)
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
                showsTimeAccent: isCurrentOrNext(settlingListCard.card, in: days)
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
            ZStack {
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

                HStack(spacing: 0) {
                    Button {
                        showsSharingSheet = true
                    } label: {
                        Image("icon-link-outline")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .frame(width: 40, height: 40)
                    }
                    .itineraryHeaderButtonStyle()
                    .disabled(!syncEngine.isUserAuthenticated || syncEngine.selectedTripID == nil)
                    .accessibilityLabel(Text("itinerary.shareTripA11y"))

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
            .frame(height: 48)
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Text(trip.destination?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "common.unnamedTrip"))
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Button { showsTripEditor = true } label: {
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
        ScrollViewReader { scrollProxy in
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
                            itineraryDayContent(trip: trip, day: day, days: days)
                        } header: {
                            itineraryDayHeader(day)
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
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, metrics in
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
                itineraryCardFrames = frames
                settleReleasedListCardIfReady(using: frames)
            }
            .onPreferenceChange(ItineraryDayFramesPreferenceKey.self) { frames in
                itineraryDayFrames = frames
            }
            .onPreferenceChange(ItineraryScrollViewportFramePreferenceKey.self) { frame in
                itineraryScrollViewportFrame = frame
            }
        }
    }

    private func itineraryDayHeader(_ day: TripDaySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ItineraryListPresentation.monthDay(for: day))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)

            Text(ItineraryListPresentation.weekday(for: day))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            Text(ItineraryListPresentation.daySummary(for: day))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

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
        days: [TripDaySnapshot]
    ) -> some View {
        let cards = orderedListCards(for: day)
        VStack(alignment: .leading, spacing: 10) {
            if cards.isEmpty {
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
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    VStack(alignment: .leading, spacing: 10) {
                        itineraryCompactCard(
                            card,
                            index: index,
                            day: day,
                            cards: cards,
                            days: days
                        )

                        if index < cards.count - 1,
                           let originPoint = card.place?.point,
                           let destinationPoint = cards[index + 1].place?.point {
                            CardLegEstimateView(
                                originCard: card,
                                destinationCard: cards[index + 1],
                                originPoint: originPoint,
                                destinationPoint: destinationPoint,
                                presentation: .itineraryList
                            )
                            .id(CardLegStore.legKey(origin: card, destination: cards[index + 1]))
                            .padding(.horizontal, 2)
                        }
                    }
                    .offset(y: placeholderOffset(for: card, in: day, cards: cards))
                    .animation(.snappy(duration: 0.2), value: draggedListCardDestinationIndex)
                    .animation(.snappy(duration: 0.2), value: draggedListCardDestinationDayID)
                    .zIndex(draggedListCard?.cardID == card.id ? 100 : 0)
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
        days: [TripDaySnapshot]
    ) -> some View {
        let canReorder = !syncEngine.isUserAuthenticated || cards.allSatisfy { $0.serverID != nil }
        let isDragging = draggedListCard?.cardID == card.id || settlingListCard?.card.id == card.id

        if canReorder {
            itinerarySwipeableCard(card, index: index, day: day, days: days)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ItineraryCardFramesPreferenceKey.self,
                            value: [card.id: proxy.frame(in: .named("itinerary-list-root"))]
                        )
                    }
                }
                .opacity(isDragging ? 0 : 1)
                .accessibilityHint(Text("itinerary.cardDetailHint"))
        } else {
            itinerarySwipeableCard(card, index: index, day: day, days: days)
                .accessibilityHint(Text("itinerary.cardDetailHintSyncing"))
        }
    }

    private func itinerarySwipeableCard(
        _ card: TravelCardSnapshot,
        index: Int,
        day: TripDaySnapshot,
        days: [TripDaySnapshot]
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
                showsTimeAccent: isCurrentOrNext(card, in: days)
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
        showsTimeAccent: Bool
    ) -> some View {
        if card.kind == .flight {
            itineraryFlightCardContent(card, isActive: showsTimeAccent)
        } else {
            ZStack(alignment: .leading) {
                if showsTimeAccent {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(PrimaryTabPalette.accent)
                }

                Group {
                    if card.showLargeImage, CardImageURL.resolve(card.images?.first) != nil {
                        itineraryLargeImageCardContent(card, index: index)
                    } else {
                        itineraryOrdinaryCardContent(card, index: index)
                    }
                }
                .padding(.leading, showsTimeAccent ? 6 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func itineraryFlightCardContent(
        _ card: TravelCardSnapshot,
        isActive: Bool
    ) -> some View {
        let price = compactCardPrice(for: card)
        let summary = ItineraryListPresentation.cardSummary(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                detailCard = card
            }
        } label: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 11) {
                        AirlineLogoBadge(
                            logoURL: itineraryAirlineLogoURL(for: card),
                            size: 38,
                            cornerRadius: 11
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AgentFlightDisplay.routeTitle(
                                from: card.fromAirport,
                                to: card.toAirport,
                                fallback: card.title
                            ))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(itineraryFlightNumber(for: card))
                                .font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
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

                    HStack(alignment: .center, spacing: 9) {
                        itineraryFlightAirportBlock(
                            airport: card.fromAirport,
                            time: itineraryFlightTime(card.startAt),
                            alignment: .leading
                        )
                        VStack(spacing: 6) {
                            Image(systemName: "airplane")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                            HStack(spacing: 4) {
                                Circle().fill(Color.white.opacity(0.24)).frame(width: 4, height: 4)
                                Rectangle().fill(Color.white.opacity(0.17)).frame(height: 1)
                                Circle().fill(Color.white.opacity(0.24)).frame(width: 4, height: 4)
                            }
                            Text(Self.itineraryFlightDateFormatter.string(from: card.startAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        itineraryFlightAirportBlock(
                            airport: card.toAirport,
                            time: card.endAt.map { itineraryFlightTime($0) } ?? String(localized: "agent.timePending"),
                            alignment: .trailing
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

                itineraryFlightTicketDivider(isActive: isActive)

                HStack(spacing: 8) {
                    if let airlineName = card.airlineName?.nilIfEmpty {
                        Text(airlineName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .lineLimit(1)
                    } else {
                        Label(card.kind.title, systemImage: "airplane")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
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
                .frame(minHeight: 40)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
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

    private func itineraryFlightAirportBlock(
        airport: String?,
        time: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(AgentFlightDisplay.airportCode(airport))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.72)
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

    private func itineraryFlightTicketDivider(isActive: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<18, id: \.self) { _ in
                Capsule().fill(Color.white.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            if !isActive {
                Circle().fill(JourneyPalette.listSurface).frame(width: 16, height: 16).offset(x: -8)
            }
        }
        .overlay(alignment: .trailing) {
            if !isActive {
                Circle().fill(JourneyPalette.listSurface).frame(width: 16, height: 16).offset(x: 8)
            }
        }
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

    private func itineraryFlightTime(_ date: Date) -> String {
        Self.itineraryFlightTimeFormatter.string(from: date)
    }

    private static let itineraryFlightTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let itineraryFlightDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private func itineraryOrdinaryCardContent(
        _ card: TravelCardSnapshot,
        index: Int
    ) -> some View {
        let summary = ItineraryListPresentation.cardSummary(for: card)
        let price = compactCardPrice(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                detailCard = card
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
                    Text(String(format: String(localized: "itinerary.cardTitle"), index + 1, card.title))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    HStack(spacing: 14) {
                        compactCardMetadata(
                            icon: "icon-pin-outline",
                            text: ItineraryListPresentation.timeRange(for: card)
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
                            .lineLimit(4)
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
        index: Int
    ) -> some View {
        let summary = ItineraryListPresentation.cardSummary(for: card)
        let price = compactCardPrice(for: card)

        return Button {
            guard suppressedListCardTapID != card.id else { return }
            if revealedListCardID != nil {
                closeListCardActions()
            } else {
                detailCard = card
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
                            Text(String(format: String(localized: "itinerary.cardTitle"), index + 1, card.title))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)

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
                        .lineLimit(4)
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
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.76))
    }

    private func compactCardPrice(for card: TravelCardSnapshot) -> String? {
        let currency = syncEngine.trip?.currency
        return CardPrice.format(minor: card.actualPriceMinor, currency: currency)
            ?? CardPrice.format(minor: card.priceMinor, currency: currency)
            ?? CardPrice.format(minor: card.ticketPriceMinor, currency: currency)
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
                if itineraryCardFrames[card.id]?.contains(location) == true {
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

    /// A persistent, touch-friendly action strip replaces the compact system
    /// toolbar. It keeps the six primary journey actions visible in the same
    /// order as the visual design while retaining their previous behavior.
    private var journeyActionBar: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { section.toggle() }
            } label: {
                Image("icon-mapview-outline")
                    .journeyActionIcon()
            }
            .accessibilityLabel(section.alternateTitle)

            Menu {
                ForEach(syncEngine.trips) { summary in
                    Button {
                        Task { await syncEngine.selectTrip(summary.id) }
                    } label: {
                        if summary.id == syncEngine.selectedTripID {
                            Label(summary.displayName, systemImage: "checkmark")
                        } else {
                            Text(summary.displayName)
                        }
                    }
                }
                Divider()
                Button("itinerary.newTripMenu", systemImage: "plus") { showsNewTripEditor = true }
            } label: {
                Image("icon-plan-outline")
                    .journeyActionIcon()
            }
            .accessibilityLabel(Text("itinerary.switchTripA11y"))

            Button {
                showsSharingSheet = true
            } label: {
                Image("icon-adduser-outline")
                    .journeyActionIcon()
            }
            .disabled(!syncEngine.isUserAuthenticated || syncEngine.selectedTripID == nil)
            .accessibilityLabel(Text("itinerary.membersA11y"))

            Button { Task { await syncEngine.retry() } } label: {
                Image("icon-reload-outline")
                    .journeyActionIcon()
            }
            .accessibilityLabel(Text("itinerary.resyncA11y"))

            Button { showsSignOutConfirmation = true } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .journeyActionIcon()
            }
            .disabled(!appleSignIn.isAuthenticated)
            .accessibilityLabel(Text("itinerary.signOutA11y"))

            Button {
                agentSheet = ItineraryAgentSheet(initialMessage: nil)
            } label: {
                Image("icon-ai-outline")
                    .journeyActionIcon()
            }
            .disabled(syncEngine.trip?.isConfigured != true)
            .accessibilityLabel(Text("itinerary.aiFillA11y"))
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(JourneyPalette.toolbarFill, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.13), lineWidth: 1) }
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
                .minimumScaleFactor(0.7)
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
            Button("common.edit") { showsTripEditor = true }
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
                                    .onTapGesture { detailCard = card }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint(Text(String(format: String(localized: "itinerary.openDetailHint"), card.title)))
                                }
                                if cardIndex < cards.count - 1,
                                   let originPoint = card.place?.point,
                                   let destinationPoint = cards[cardIndex + 1].place?.point {
                                    CardLegEstimateView(
                                        originCard: card,
                                        destinationCard: cards[cardIndex + 1],
                                        originPoint: originPoint,
                                        destinationPoint: destinationPoint
                                    )
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
                    Text(ExpenseMoney.formatted(expenses.reduce(Int64(0)) { $0 + $1.amountMinor }, currency: currency))
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
                            Text(ExpenseMoney.formatted(expense.amountMinor, currency: currency))
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

    private func applyDragLock() {
        guard let scrollView,
              scrollView.panGestureRecognizer.isEnabled == isDragLocked else { return }
        scrollView.panGestureRecognizer.isEnabled = !isDragLocked
    }
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

private struct ItineraryScrollMetrics: Equatable {
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

enum ItineraryListPresentation {
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
        guard let todayDate = dayFormatter.date(from: todayString) else { return 0 }
        return days.enumerated().min { left, right in
            abs((dayFormatter.date(from: left.element.date) ?? .distantPast).timeIntervalSince(todayDate))
                < abs((dayFormatter.date(from: right.element.date) ?? .distantPast).timeIntervalSince(todayDate))
        }?.offset ?? 0
    }

    static func timelineLabel(_ day: TripDaySnapshot, _ isToday: Bool) -> String {
        guard let date = dayFormatter.date(from: day.date) else { return day.date }
        let weekday = weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return isToday
            ? String(format: String(localized: "common.timelineToday"), weekday)
            : String(format: String(localized: "common.timelineDate"), numericFormatter.string(from: date), weekday)
    }

    static func monthDay(for day: TripDaySnapshot) -> String {
        guard let date = dayFormatter.date(from: day.date) else { return day.date }
        return numericFormatter.string(from: date)
    }

    static func weekday(for day: TripDaySnapshot) -> String {
        guard let date = dayFormatter.date(from: day.date) else { return "" }
        return weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }

    static func daySummary(for day: TripDaySnapshot) -> String {
        let titles = orderedCards(day.cards)
            .prefix(2)
            .map { ($0.place?.name.nilIfEmpty ?? $0.title).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return String(localized: "itinerary.daySummaryEmpty") }
        return String(titles.joined(separator: String(localized: "lottery.contextSeparator")).prefix(8))
    }

    static func orderedCards(_ cards: [TravelCardSnapshot]) -> [TravelCardSnapshot] {
        cards.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
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

    static func timeRange(for card: TravelCardSnapshot) -> String {
        let start = timeFormatter.string(from: card.startAt)
        guard let endAt = card.endAt else { return start }
        return String(format: String(localized: "itinerary.cardTimeRange"), start, timeFormatter.string(from: endAt))
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

    private static let numericFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM.dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

private extension Image {
    func journeyActionIcon() -> some View {
        self
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 27, height: 27)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
            .opacity(1)
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
