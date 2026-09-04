import SwiftUI
import SwiftData

enum CardLegEstimatePresentation {
    case standard
    case itineraryList
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
    /// 估算结果变化时上报耗时（秒）；失败/清空时上报 nil。行程列表据此把
    /// 相邻卡的交通耗时算进轨道时间线（最晚出发时刻）。
    var onDurationChange: ((Int?) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @StateObject private var mapLinkHandler = MapLinkHandler()
    @State private var mode: RouteMode = .driving
    @State private var estimate: CachedRouteEstimate?
    @State private var isFetching = false
    @State private var fetchFailed = false

    private var legKey: String { CardLegStore.legKey(origin: originCard, destination: destinationCard) }

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardContent
            case .itineraryList:
                itineraryListContent
            }
        }
        .task(id: legKey) {
            await load()
        }
        .onChange(of: estimate) { _, newValue in
            onDurationChange?(newValue?.estimate.durationSeconds)
        }
        .alert("routeSheet.cannotOpenMap", isPresented: Binding(get: { mapLinkHandler.alertMessage != nil }, set: { if !$0 { mapLinkHandler.alertMessage = nil } })) {
            Button("common.ok", role: .cancel) { mapLinkHandler.alertMessage = nil }
        } message: {
            Text(mapLinkHandler.alertMessage ?? "")
        }
    }

    private var standardContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary)
            if isFetching {
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

    private var itineraryListContent: some View {
        Button(action: openRoute) {
            HStack(spacing: 8) {
                itineraryListModeIcon

                Group {
                    if isFetching {
                        ProgressView()
                            .controlSize(.small)
                        Text("leg.estimateRunning")
                    } else if let estimate {
                        Text(
                            "\(Self.itineraryListDistanceText(estimate.estimate.distanceMeters)) • "
                                + Self.itineraryListDurationText(estimate.estimate.durationSeconds)
                        )
                    } else {
                        Text(fetchFailed ? String(localized: "leg.estimateFailed") : String(localized: "leg.estimatePending"))
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))

                Spacer(minLength: 8)

                Image("icon-right-outline")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
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
        .accessibilityLabel(itineraryListAccessibilityLabel)
        .accessibilityHint(Text("leg.hint"))
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
        mode = newMode
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
        let store = CardLegStore(modelContext: modelContext)
        let routeKey = failureKey(for: mode)
        guard !store.hasEstimateFailure(routeKey: routeKey, for: legKey) else {
            estimate = nil
            fetchFailed = true
            return
        }
        isFetching = true
        defer { isFetching = false }
        let cache = RouteCache(modelContext: modelContext)
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true) {
            estimate = cached
            fetchFailed = false
            return
        }
        do {
            let result = try await AppleMapService.estimateRoute(origin: originPoint, destination: destinationPoint, mode: mode)
            try? cache.store(result, origin: originPoint, destination: destinationPoint, mode: mode)
            estimate = CachedRouteEstimate(estimate: result, cachedAt: .now)
            fetchFailed = false
            store.clearEstimateFailure(routeKey: routeKey, for: legKey)
        } catch {
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
