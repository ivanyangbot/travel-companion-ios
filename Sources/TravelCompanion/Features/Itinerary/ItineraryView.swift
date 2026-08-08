import AuthenticationServices
import SwiftUI

struct ItineraryView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var sharedLinkStore: PendingSharedLinkStore
    @ObservedObject var appleSignIn: AppleSignInStore
    @Binding var section: JourneyView.Section
    @State private var activeDaySheet: DaySheet?
    @State private var showsTripEditor = false
    @State private var showsNewTripEditor = false
    @State private var showsSignOutConfirmation = false
    @State private var showsAIItinerary = false
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
    @StateObject private var linkHandler = ExternalLinkHandler()

    var body: some View {
        NavigationStack {
            alertContent
            .alert("删除日期？", isPresented: Binding(
                get: { dayPendingDeletion != nil },
                set: { if !$0 { dayPendingDeletion = nil } }
            ), presenting: dayPendingDeletion) { day in
                Button("删除", role: .destructive) {
                    Task { await syncEngine.deleteDay(day) }
                    dayPendingDeletion = nil
                }
                Button("取消", role: .cancel) { dayPendingDeletion = nil }
            } message: { _ in
                Text("日期内含有行程卡片时，服务器会拒绝删除。")
            }
            .alert("退出登录？", isPresented: $showsSignOutConfirmation) {
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
            .alert("删除行程卡片？", isPresented: Binding(
                get: { cardPendingDeletion != nil },
                set: { if !$0 { cardPendingDeletion = nil } }
            ), presenting: cardPendingDeletion) { card in
                Button("删除", role: .destructive) {
                    Task { await syncEngine.deleteCard(card) }
                    cardPendingDeletion = nil
                }
                Button("取消", role: .cancel) { cardPendingDeletion = nil }
            } message: { _ in
                Text("删除后会同步移除这张公开共享卡片。")
            }
            .alert("无法打开链接", isPresented: Binding(
                get: { linkHandler.alertMessage != nil },
                set: { if !$0 { linkHandler.alertMessage = nil } }
            )) {
                Button("好", role: .cancel) { linkHandler.alertMessage = nil }
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
            .sheet(isPresented: $showsAIItinerary) {
                AgentWorkbenchView(syncEngine: syncEngine)
            }
            .sheet(item: $detailCard) { card in
                CardDetailView(card: card, currency: syncEngine.trip?.currency)
                    .presentationDragIndicator(.visible)
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
                    "无法加载共享行程",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
                Button("重试") { Task { await syncEngine.retry() } }
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
            ProgressView("正在打开共享行程…")
        }
    }

    private func detailedItinerary(_ trip: SharedTripSnapshot) -> some View {
        let days = trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
        let todayIndex = ItineraryListPresentation.todayIndex(in: days)
        let selectedIndex = ItineraryListPresentation.selectedIndex(
            date: selectedListDate,
            in: days
        )

        return GeometryReader { geometry in
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
                        Label("还没有日期", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("添加旅行日期后即可安排卡片。")
                    } actions: {
                        Button("添加日期") { activeDaySheet = .add }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    itineraryDayScroller(trip: trip, days: days)
                }
            }
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
                Text("详细行程")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 0) {
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
                    .accessibilityLabel("切换到地图模式")

                    Spacer(minLength: 0)
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Text(trip.destination?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未命名旅程")
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
                .accessibilityLabel("编辑行程")

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
                if !appleSignIn.isAuthenticated {
                    signInBanner
                        .padding(.horizontal, 16)
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 112)
            }
            .coordinateSpace(name: "itinerary-day-scroll")
            .scrollIndicators(.hidden)
            .onChange(of: programmaticScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth(duration: 0.34)) {
                    scrollProxy.scrollTo(target, anchor: .top)
                }
            }
            .onPreferenceChange(ItineraryDayHeaderOffsetsPreferenceKey.self) { offsets in
                updateSelectedDay(from: offsets, days: days)
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
            Button("添加行程卡片", systemImage: "plus") { activeCardEditor = .create(day) }
            Button("编辑日期", systemImage: "calendar") { activeDaySheet = .edit(day) }
            Button("删除日期", systemImage: "trash", role: .destructive) { dayPendingDeletion = day }
                .disabled(day.serverID == nil && syncEngine.isUserAuthenticated)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("长按可添加卡片或编辑日期")
    }

    @ViewBuilder
    private func itineraryDayContent(
        trip: SharedTripSnapshot,
        day: TripDaySnapshot,
        days: [TripDaySnapshot]
    ) -> some View {
        let cards = day.cards.sorted(by: Self.cardTimeOrder)
        VStack(spacing: 10) {
            if cards.isEmpty {
                Button {
                    activeCardEditor = .create(day)
                } label: {
                    Label("这一天还没有行程，点击添加", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 78)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    itineraryCompactCard(
                        card,
                        index: index,
                        day: day,
                        cards: cards
                    )

                    if index < cards.count - 1,
                       let originPoint = card.place?.point,
                       let destinationPoint = cards[index + 1].place?.point {
                        CardLegEstimateView(
                            originCard: card,
                            destinationCard: cards[index + 1],
                            originPoint: originPoint,
                            destinationPoint: destinationPoint
                        )
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .background(JourneyPalette.listSurface)
    }

    private func itineraryCompactCard(
        _ card: TravelCardSnapshot,
        index: Int,
        day: TripDaySnapshot,
        cards: [TravelCardSnapshot]
    ) -> some View {
        Button {
            detailCard = card
        } label: {
            HStack(alignment: .top, spacing: 10) {
                itineraryCardCover(card)
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1).\(card.title)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Label(ItineraryListPresentation.timeRange(for: card), systemImage: card.kind.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)

                    if let summary = ItineraryListPresentation.cardSummary(for: card) {
                        Text(summary)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(height: 58)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(JourneyPalette.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑", systemImage: "pencil") { activeCardEditor = .edit(day, card) }
            Button("上移", systemImage: "arrow.up") {
                Task { await syncEngine.moveCard(card, in: day, direction: -1) }
            }
            .disabled(index == 0 || (card.serverID == nil && syncEngine.isUserAuthenticated))
            Button("下移", systemImage: "arrow.down") {
                Task { await syncEngine.moveCard(card, in: day, direction: 1) }
            }
            .disabled(index == cards.count - 1 || (card.serverID == nil && syncEngine.isUserAuthenticated))
            Button("删除", systemImage: "trash", role: .destructive) { cardPendingDeletion = card }
        }
        .accessibilityHint("打开详情；长按可编辑或调整顺序")
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
                Button("新建旅程", systemImage: "plus") { showsNewTripEditor = true }
            } label: {
                Image("icon-plan-outline")
                    .journeyActionIcon()
            }
            .accessibilityLabel("切换旅程")

            Button {
                showsSharingSheet = true
            } label: {
                Image("icon-adduser-outline")
                    .journeyActionIcon()
            }
            .disabled(!syncEngine.isUserAuthenticated || syncEngine.selectedTripID == nil)
            .accessibilityLabel("查看共享成员")

            Button { Task { await syncEngine.retry() } } label: {
                Image("icon-reload-outline")
                    .journeyActionIcon()
            }
            .accessibilityLabel("重新同步")

            Button { showsSignOutConfirmation = true } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .journeyActionIcon()
            }
            .disabled(!appleSignIn.isAuthenticated)
            .accessibilityLabel("退出登录")

            Button {
                showsAIItinerary = true
            } label: {
                Image("icon-ai-outline")
                    .journeyActionIcon()
            }
            .disabled(syncEngine.trip?.isConfigured != true)
            .accessibilityLabel("AI 填入行程")
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
                    Text("未登录·本地模式")
                        .font(.headline)
                    Text("全部功能均可使用，旅行内容会先保存在本机；登录后再开启云端同步。")
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
                        Text("正在登录…")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("正在登录")
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
            Text(trip.destination ?? "未设置目的地")
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
            Button("编辑") { showsTripEditor = true }
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
                    Text("时间轴").font(.system(size: 30, weight: .black, design: .rounded))
                    Spacer()
                    Button("添加日期", systemImage: "plus") { activeDaySheet = .add }
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(JourneyPalette.controlFill, in: Capsule())
                        .overlay { Capsule().stroke(JourneyPalette.actionBlue.opacity(0.75), lineWidth: 1) }
                        .buttonStyle(.plain)
                }
                let days = trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
                ForEach(days, id: \.id) { day in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(day.date).font(.title2.weight(.black))
                            Spacer()
                            Button(role: .destructive) { dayPendingDeletion = day } label: { Image(systemName: "trash") }
                                .journeyRoundControl()
                                .disabled(day.serverID == nil && syncEngine.isUserAuthenticated)
                                .accessibilityLabel("删除日期")
                            Button { activeCardEditor = .create(day) } label: { Image(systemName: "plus") }
                                .journeyRoundControl()
                                .accessibilityLabel("添加行程卡片")
                        }
                        Text("行程卡片").font(.title3.weight(.black))
                        let cards = day.cards.sorted(by: Self.cardTimeOrder)
                        if !cards.isEmpty && !cards.contains(where: { $0.kind == .hotel }) {
                            Label("今日未添加住宿", systemImage: "bed.double")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.38))
                        }
                        if cards.isEmpty {
                            Label("暂无行程卡片", systemImage: "rectangle.stack")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("添加机票、酒店或活动，订单号和公开网页链接会随卡片保存。")
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
                                    .accessibilityHint("打开 \(card.title) 的完整行程与 POI 详情")
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
                    ContentUnavailableView("还没有日期", systemImage: "calendar.badge.plus", description: Text("添加旅行日期后即可安排卡片。"))
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
            .accessibilityLabel("开始时间 \(Self.cardTimeFormatter.string(from: card.startAt))")
    }

    /// 当日实际价支出：按 occurredOn == day.date 过滤，绑定到行程当日页。
    @ViewBuilder
    private func dayExpensesSection(trip: SharedTripSnapshot, day: TripDaySnapshot) -> some View {
        let expenses = trip.expenses.filter { $0.occurredOn == day.date }.sorted { $0.updatedAt > $1.updatedAt }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当日实际支出").font(.subheadline.weight(.semibold))
                Spacer()
                if let currency = trip.currency {
                    Text(ExpenseMoney.formatted(expenses.reduce(Int64(0)) { $0 + $1.amountMinor }, currency: currency))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if expenses.isEmpty {
                Text("这一天还没有记录实际价。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(expenses) { expense in
                    HStack(spacing: 8) {
                        Image(systemName: expense.category.systemImage)
                            .foregroundStyle(.secondary)
                        Text(expense.category.title).font(.subheadline)
                        if let note = expense.note, !note.isEmpty {
                            Text("· \(note)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let currency = trip.currency {
                            Text(ExpenseMoney.formatted(expense.amountMinor, currency: currency))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }
            Button("添加实际支出", systemImage: "plus") {
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
        case .loading: return "正在加载"
        case .synced: return nil
        case .syncing: return nil
        case .pending(let count): return "待同步 \(count) 项"
        case .conflict: return "可能覆盖"
        case .localOnly: return appleSignIn.isAuthenticated ? nil : "本地模式·全部功能可用"
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

private struct ItineraryDayHeaderOffsetsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] { [:] }

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

enum ItineraryListPresentation {
    private static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

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
        return isToday ? "今日 \(weekday)" : "\(numericFormatter.string(from: date)) \(weekday)"
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
        let titles = day.cards
            .sorted {
                if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .prefix(2)
            .map { ($0.place?.name.nilIfEmpty ?? $0.title).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return "尚未安排行程" }
        return String(titles.joined(separator: "，").prefix(8))
    }

    static func timeRange(for card: TravelCardSnapshot) -> String {
        let start = timeFormatter.string(from: card.startAt)
        guard let endAt = card.endAt else { return start }
        return "\(start)~\(timeFormatter.string(from: endAt))"
    }

    static func cardSummary(for card: TravelCardSnapshot) -> String? {
        for candidate in [card.description, card.notes] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        let tips = card.tips?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return tips?.isEmpty == false ? tips?.joined(separator: " · ") : nil
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
