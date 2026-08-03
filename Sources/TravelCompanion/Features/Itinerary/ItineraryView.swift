import SwiftUI

struct ItineraryView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var sharedLinkStore: PendingSharedLinkStore
    @State private var activeDaySheet: DaySheet?
    @State private var showsTripEditor = false
    @State private var showsAPISettings = false
    @State private var showsAIItinerary = false
    @State private var dayPendingDeletion: TripDaySnapshot?
    @State private var activeCardEditor: CardEditorTarget?
    @State private var detailCard: TravelCardSnapshot?
    @State private var aiItinerarySeed: String?
    @State private var cardPendingDeletion: TravelCardSnapshot?
    @State private var expenseEditorDate: Date?
    @StateObject private var linkHandler = ExternalLinkHandler()

    var body: some View {
        NavigationStack {
            Group {
                if let trip = syncEngine.trip {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if trip.isConfigured {
                                tripHeader(trip)
                                timeline(trip)
                            } else {
                                TripSetupSheet { destination, startDate, endDate, currency in
                                    Task { await syncEngine.saveSetup(destination: destination, startDate: startDate, endDate: endDate, currency: currency) }
                                }
                            }
                        }
                        .padding()
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
                } else {
                    ProgressView("正在打开共享行程…")
                }
            }
            .navigationTitle("旅程")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await syncEngine.retry() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新同步")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsAPISettings = true } label: { Image(systemName: "gear") }
                        .accessibilityLabel("连接设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        aiItinerarySeed = nil
                        showsAIItinerary = true
                    } label: { Image(systemName: "sparkles") }
                        .disabled(syncEngine.trip?.isConfigured != true)
                        .accessibilityLabel("AI 填入行程")
                }
            }
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
            .sheet(isPresented: $showsAPISettings) {
                APISettingsView(initialURL: syncEngine.apiBaseURLText) { url in
                    let validationMessage = syncEngine.updateAPIBaseURL(url)
                    if validationMessage == nil {
                        Task { await syncEngine.retry() }
                    }
                    return validationMessage
                }
            }
            .sheet(isPresented: $showsAIItinerary, onDismiss: { aiItinerarySeed = nil }) {
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
            .onChange(of: sharedLinkStore.pendingURL) { _, _ in
                presentSharedLinkIfPossible()
            }
            .onChange(of: syncEngine.trip?.version) { _, _ in
                presentSharedLinkIfPossible()
            }
            .task {
                presentSharedLinkIfPossible()
            }
        }
    }

    private func tripHeader(_ trip: SharedTripSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.destination ?? "未设置目的地")
                .font(.largeTitle.bold())
            Text([trip.startDate, trip.endDate].compactMap { $0 }.joined(separator: " — "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(trip.currency ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular.tint(.indigo), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button("编辑") { showsTripEditor = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .padding(12)
        }
    }

    private func timeline(_ trip: SharedTripSnapshot) -> some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("时间轴").font(.title3.bold())
                    Spacer()
                    Button("添加日期", systemImage: "plus") { activeDaySheet = .add }
                        .buttonStyle(.glass)
                }
                let days = trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
                ForEach(days, id: \.id) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(day.date).font(.headline)
                            Spacer()
                            Button(role: .destructive) { dayPendingDeletion = day } label: { Image(systemName: "trash") }
                                .buttonStyle(.glass)
                                .disabled(day.serverID == nil)
                                .accessibilityLabel("删除日期")
                        }
                        Text("行程卡片").font(.subheadline.weight(.semibold))
                        let cards = day.cards.sorted(by: Self.cardTimeOrder)
                        if !cards.isEmpty && !cards.contains(where: { $0.kind == .hotel }) {
                            Label("今日未添加住宿", systemImage: "bed.double")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
                                        canMoveUp: cardIndex > 0 && card.serverID != nil,
                                        canMoveDown: cardIndex < cards.count - 1 && card.serverID != nil,
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
                    .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                if trip.days.isEmpty {
                    ContentUnavailableView("还没有日期", systemImage: "calendar.badge.plus", description: Text("添加旅行日期后即可安排卡片。"))
                }
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
            .buttonStyle(.glass)
            .font(.caption.weight(.semibold))
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

    private func presentSharedLinkIfPossible() {
        guard !showsAIItinerary,
              activeCardEditor == nil,
              let url = sharedLinkStore.pendingURL,
              syncEngine.trip?.isConfigured == true else { return }
        aiItinerarySeed = url.absoluteString
        showsAIItinerary = true
        sharedLinkStore.markDelivered()
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
        case .offline(let message), .failed(let message): return message
        }
    }
}
