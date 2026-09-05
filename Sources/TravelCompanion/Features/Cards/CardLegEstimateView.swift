import SwiftUI
import SwiftData

enum CardLegEstimatePresentation {
    case standard
    case itineraryList
    case itineraryDayStart
}

/// Compare absolute instants; local clock offsets and DST must not affect slack.
enum ItineraryConnectionTiming {
    static func arrival(origin: TravelCardSnapshot, duration: Int) -> Date? {
        guard origin.kind != .hotel, duration >= 0,
              let end = origin.endAt, end > origin.startAt else { return nil }
        return end.addingTimeInterval(Double(duration))
    }

    static func shortageMinutes(arrival: Date, destination: TravelCardSnapshot) -> Int? {
        // Hotel check-in is a policy window, not an appointment deadline.
        guard destination.kind != .hotel, arrival > destination.startAt else { return nil }
        return Int(ceil(arrival.timeIntervalSince(destination.startAt) / 60))
    }
}

/// 相邻两张有坐标的卡片之间的出行时间预估。默认驾车，每段可单独切换并持久化；
/// 首次无缓存时通过 Apple MapKit 静默估算一次，之后始终显示本地缓存值；
/// 失败也会持久缓存，只有页面左上角菜单的刷新动作会统一清除并重新请求。
struct CardLegEstimateView: View {
    let originCard: TravelCardSnapshot
    let destinationCard: TravelCardSnapshot
    let originPoint: RoutePoint
    let destinationPoint: RoutePoint
    var presentation: CardLegEstimatePresentation = .standard
    var destinationTimeZone: TimeZone? = nil

    @Environment(\.modelContext) private var modelContext
    @StateObject private var mapLinkHandler = MapLinkHandler()
    @State private var mode: RouteMode = .driving
    @State private var estimate: CachedRouteEstimate?
    @State private var isFetching = false
    @State private var fetchFailed = false
    @State private var estimateRequestID = UUID()
    @State private var manualDuration: Int?
    @State private var showsDurationEditor = false
    @State private var durationHours = 0
    @State private var durationMinutes = 30
    @State private var durationSaveFailed = false

    private var effectiveDuration: Int? { manualDuration ?? estimate?.estimate.durationSeconds }

    /// 当前段的衔接缺口（分钟）：按有效时长推算到达，晚于下一卡开始才算
    /// 不足；无法推算时为 nil。行内的三角感叹号以此为准。
    private var connectionShortageMinutes: Int? {
        guard let duration = effectiveDuration,
              manualDuration != nil || !isFetching,
              let arrival = ItineraryConnectionTiming.arrival(origin: originCard, duration: duration) else {
            return nil
        }
        return ItineraryConnectionTiming.shortageMinutes(arrival: arrival, destination: destinationCard)
    }

    private var legKey: String { CardLegStore.legKey(origin: originCard, destination: destinationCard) }

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardContent
            case .itineraryList:
                itineraryListContent
            case .itineraryDayStart:
                itineraryDayStartContent
            }
        }
        .task(id: legKey) {
            await load()
        }
        .sheet(isPresented: $showsDurationEditor) { durationEditor }
        .alert("routeSheet.cannotOpenMap", isPresented: Binding(get: { mapLinkHandler.alertMessage != nil }, set: { if !$0 { mapLinkHandler.alertMessage = nil } })) {
            Button("common.ok", role: .cancel) { mapLinkHandler.alertMessage = nil }
        } message: {
            Text(mapLinkHandler.alertMessage ?? "")
        }
    }

    private var standardContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary)
            if let manualDuration {
                Text(Self.itineraryListDurationText(manualDuration)).font(.caption.weight(.medium))
                Text("leg.manualDuration").font(.caption2).foregroundStyle(.orange)
            } else if isFetching {
                ProgressView().controlSize(.small)
            } else if let estimate {
                Text(Self.durationText(estimate.estimate.durationSeconds))
                    .font(.caption.weight(.medium))
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text(Self.distanceText(estimate.estimate.distanceMeters))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(fetchFailed ? String(localized: "leg.estimateFailed") : String(localized: "leg.estimatePending"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: editDuration) { Image(systemName: "pencil").frame(minWidth: 32, minHeight: 32) }
                .accessibilityLabel(Text("leg.editDuration"))
            Menu {
                ForEach(RouteMode.allCases) { option in
                    Button {
                        changeMode(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            } label: {
                Image(systemName: mode.systemImage).frame(minWidth: 28, minHeight: 28)
            }
            .accessibilityLabel(Text(String(format: String(localized: "leg.modeA11y"), mode.title)))
            Button {
                mapLinkHandler.openRoute(
                    origin: originPoint,
                    originName: originCard.place?.name ?? originCard.title,
                    destination: destinationPoint,
                    destinationName: destinationCard.place?.name ?? destinationCard.title,
                    mode: mode
                )
            } label: {
                Image(systemName: "location.fill")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .accessibilityLabel(Text("leg.navigateA11y"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(in: Capsule())
    }

    @ViewBuilder
    private var itineraryListContent: some View {
        itineraryRouteRow(dayStart: false)
            .contextMenu { modeMenu }
            .accessibilityElement(children: .contain)
    }

    private var itineraryDayStartContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("leg.fromPreviousHotel", systemImage: "bed.double.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PrimaryTabPalette.accent)
                .lineLimit(1)
            itineraryRouteRow(dayStart: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PrimaryTabPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(PrimaryTabPalette.accent.opacity(0.22), lineWidth: 1)
        }
        .contextMenu { modeMenu }
    }

    private func itineraryRouteRow(dayStart: Bool) -> some View {
        HStack(spacing: 5) {
            Button(action: openRoute) {
                HStack(spacing: 6) {
                    itineraryListModeIcon

                    if isFetching, manualDuration == nil {
                        ProgressView().controlSize(.mini)
                    }
                    Text(itineraryListSummary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if let shortage = connectionShortageMinutes {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .fixedSize()
                            .accessibilityLabel(
                                Text(String(format: String(localized: "rail.connectionShortage"), shortage))
                            )
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(itineraryListAccessibilityLabel)
            .accessibilityHint(Text("leg.hint"))

            HStack(spacing: 1) {
                Button(action: editDuration) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("leg.editDuration"))

                Button(action: openRoute) {
                    Image("icon-right-outline")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 25, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("leg.navigateA11y"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: dayStart ? 30 : 34, alignment: .leading)
        .padding(.horizontal, dayStart ? 0 : 12)
        .contentShape(Rectangle())
    }

    private var itineraryListSummary: String {
        if let manualDuration {
            return "\(Self.itineraryListDurationText(manualDuration)) · \(String(localized: "leg.manualDuration"))"
        }
        if isFetching {
            return String(localized: "leg.estimateRunning")
        }
        if let estimate {
            return "\(Self.itineraryListDistanceText(estimate.estimate.distanceMeters)) · "
                + Self.itineraryListDurationText(estimate.estimate.durationSeconds)
        }
        return fetchFailed ? String(localized: "leg.estimateFailed") : String(localized: "leg.estimatePending")
    }

    @ViewBuilder
    private var modeMenu: some View {
        Section("leg.modeSection") {
            ForEach(RouteMode.allCases) { option in
                Button {
                    changeMode(option)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
        }
    }

    private func editDuration() {
        let minutes = min(2879, max(1, Int(ceil(Double(effectiveDuration ?? 1800) / 60))))
        durationHours = minutes / 60
        durationMinutes = minutes % 60
        durationSaveFailed = false
        showsDurationEditor = true
    }

    private var durationEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(originCard.title) → \(destinationCard.title)")
                        .font(.headline).lineLimit(3)
                    Label(mode.title, systemImage: mode.systemImage).foregroundStyle(.secondary)
                    HStack {
                        Picker("leg.hours", selection: $durationHours) {
                            ForEach(0..<48) { Text("\($0)").tag($0) }
                        }.pickerStyle(.wheel)
                        Text("leg.hours")
                        Picker("leg.minutes", selection: $durationMinutes) {
                            ForEach(0..<60) { Text("\($0)").tag($0) }
                        }.pickerStyle(.wheel)
                        Text("leg.minutes")
                    }.frame(height: 150)
                    if durationHours > 0 || durationMinutes > 0 {
                        connectionTiming(duration: (durationHours * 60 + durationMinutes) * 60)
                            .padding(.horizontal, -18)
                    }
                    Text("leg.durationHelp").font(.caption).foregroundStyle(.secondary)
                    if manualDuration != nil {
                        Button("leg.restoreDuration") { saveDuration(nil) }
                            .foregroundStyle(.orange)
                    }
                    if durationSaveFailed {
                        Text("leg.durationSaveFailed").font(.caption).foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .navigationTitle("leg.editDuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { showsDurationEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { saveDuration((durationHours * 60 + durationMinutes) * 60) }
                        .disabled(durationHours == 0 && durationMinutes == 0)
                }
            }
        }
        .tint(.orange)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func saveDuration(_ seconds: Int?) {
        do {
            try CardLegStore(modelContext: modelContext).setManualDuration(seconds, routeKey: failureKey(for: mode), for: legKey)
            manualDuration = seconds
            showsDurationEditor = false
        } catch {
            durationSaveFailed = true
        }
    }

    @ViewBuilder
    private func connectionTiming(duration: Int) -> some View {
        if let arrival = ItineraryConnectionTiming.arrival(origin: originCard, duration: duration) {
            let zone = destinationCard.kind == .flight
                ? ItineraryLocalTime.startTimeZone(for: destinationCard)
                : (destinationTimeZone ?? ItineraryLocalTime.placeTimeZone(for: destinationCard)
                   ?? ItineraryLocalTime.deviceTimeZone)
            let shortage = ItineraryConnectionTiming.shortageMinutes(arrival: arrival, destination: destinationCard)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: String(localized: "rail.estimatedArrival"),
                            ItineraryLocalTime.monthDay(arrival, in: zone),
                            ItineraryLocalTime.railTimeText(arrival, in: zone)))
                // 「衔接不足 X 分钟」的文字提示已上移为行内三角感叹号，
                // 这里只保留橙色着色来呼应。
                if destinationCard.kind == .flight {
                    Text("rail.flightBuffer")
                }
            }
            .font(.caption)
            .foregroundStyle(shortage == nil ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        } else {
            Text("rail.connectionUnknown")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18)
        }
    }

    @ViewBuilder
    private var itineraryListModeIcon: some View {
        if mode == .walking {
            itineraryListAssetIcon("icon-walk-outline")
        } else if mode == .driving {
            itineraryListAssetIcon("icon-car-outline")
        } else {
            Image(systemName: mode.systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private func itineraryListAssetIcon(_ name: String) -> some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 20, height: 20)
            .foregroundStyle(.white.opacity(0.82))
    }

    private var itineraryListAccessibilityLabel: String {
        if let manualDuration {
            return "\(mode.title), \(Self.itineraryListDurationText(manualDuration)), \(String(localized: "leg.manualDuration"))"
        }
        if isFetching {
            return String(format: String(localized: "leg.estimatingA11y"), mode.title)
        }
        if let estimate {
            return String(format: String(localized: "leg.resultA11y"), mode.title, Self.distanceText(estimate.estimate.distanceMeters), Self.durationText(estimate.estimate.durationSeconds))
        }
        return "\(mode.title)，\(fetchFailed ? String(localized: "leg.cannotEstimateA11y") : String(localized: "leg.estimatePending"))"
    }

    private func openRoute() {
        mapLinkHandler.openRoute(
            origin: originPoint,
            originName: originCard.place?.name ?? originCard.title,
            destination: destinationPoint,
            destinationName: destinationCard.place?.name ?? destinationCard.title,
            mode: mode
        )
    }

    private func load() async {
        let store = CardLegStore(modelContext: modelContext)
        let stored = store.mode(for: legKey)
        manualDuration = store.manualDuration(routeKey: failureKey(for: stored), for: legKey)
        if stored != mode { mode = stored }
        let cache = RouteCache(modelContext: modelContext)
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: stored, includeExpired: true) {
            estimate = cached
            fetchFailed = false
        } else if store.hasEstimateFailure(routeKey: failureKey(for: stored), for: legKey) {
            estimate = nil
            fetchFailed = true
        } else {
            await fetch()
        }
    }

    private func changeMode(_ newMode: RouteMode) {
        guard newMode != mode else { return }
        estimateRequestID = UUID()
        isFetching = false
        mode = newMode
        manualDuration = CardLegStore(modelContext: modelContext).manualDuration(routeKey: failureKey(for: newMode), for: legKey)
        CardLegStore(modelContext: modelContext).setMode(newMode, for: legKey)
        let cache = RouteCache(modelContext: modelContext)
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: newMode, includeExpired: true) {
            estimate = cached
            fetchFailed = false
        } else if CardLegStore(modelContext: modelContext).hasEstimateFailure(
            routeKey: failureKey(for: newMode),
            for: legKey
        ) {
            estimate = nil
            fetchFailed = true
        } else {
            estimate = nil
            fetchFailed = false
            Task { await fetch() }
        }
    }

    private func fetch() async {
        let requestID = UUID()
        estimateRequestID = requestID
        let requestedMode = mode
        let store = CardLegStore(modelContext: modelContext)
        let routeKey = failureKey(for: mode)
        guard !store.hasEstimateFailure(routeKey: routeKey, for: legKey) else {
            estimate = nil
            fetchFailed = true
            return
        }
        isFetching = true
        defer { if estimateRequestID == requestID { isFetching = false } }
        let cache = RouteCache(modelContext: modelContext)
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true) {
            estimate = cached
            fetchFailed = false
            return
        }
        do {
            let result = try await AppleMapService.estimateRoute(origin: originPoint, destination: destinationPoint, mode: requestedMode)
            guard estimateRequestID == requestID, !Task.isCancelled else { return }
            try? cache.store(result, origin: originPoint, destination: destinationPoint, mode: requestedMode)
            estimate = CachedRouteEstimate(estimate: result, cachedAt: .now)
            fetchFailed = false
            store.clearEstimateFailure(routeKey: routeKey, for: legKey)
        } catch {
            guard estimateRequestID == requestID, !Task.isCancelled else { return }
            estimate = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true)
            fetchFailed = estimate == nil
            if fetchFailed {
                store.markEstimateFailure(routeKey: routeKey, for: legKey)
            }
        }
    }

    private func failureKey(for mode: RouteMode) -> String {
        RouteCache.cacheKey(origin: originPoint, destination: destinationPoint, mode: mode)
    }

    private static func distanceText(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f km", Double(meters) / 1000) : "\(meters) m"
    }

    private static func durationText(_ seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        return minutes >= 60 ? String(format: String(localized: "route.durationHM"), minutes / 60, minutes % 60) : String(format: String(localized: "route.approxMin"), minutes)
    }

    static func itineraryListDistanceText(_ meters: Int) -> String {
        guard meters >= 1_000 else { return "\(meters)m" }
        let kilometers = Double(meters) / 1_000
        let formatted = String(format: "%.1f", kilometers)
        return formatted.hasSuffix(".0")
            ? "\(formatted.dropLast(2))km"
            : "\(formatted)km"
    }

    static func itineraryListDurationText(_ seconds: Int) -> String {
        "\(max(1, Int(ceil(Double(seconds) / 60))))min"
    }
}
