import SwiftUI
import SwiftData

/// 相邻两张有坐标的卡片之间的出行时间预估。默认驾车，每段可单独切换并持久化；
/// 首次无缓存时通过 Apple MapKit 静默估算一次，之后仅显示缓存值（含过期），点刷新才再次请求。
struct CardLegEstimateView: View {
    let originCard: TravelCardSnapshot
    let destinationCard: TravelCardSnapshot
    let originPoint: RoutePoint
    let destinationPoint: RoutePoint

    @Environment(\.modelContext) private var modelContext
    @StateObject private var mapLinkHandler = MapLinkHandler()
    @State private var mode: RouteMode = .driving
    @State private var estimate: CachedRouteEstimate?
    @State private var isFetching = false
    @State private var fetchFailed = false

    private var legKey: String { CardLegStore.legKey(origin: originCard, destination: destinationCard) }

    var body: some View {
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
                Text(fetchFailed ? "无法估算" : "预计时间")
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
            .accessibilityLabel("出行方式：\(mode.title)")
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
            .accessibilityLabel("在 Apple 地图中开始导航")
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(estimate.map { $0.isFresh() ? Color.secondary : Color.orange } ?? Color.secondary)
                    .frame(minWidth: 28, minHeight: 28)
            }
            .disabled(isFetching)
            .accessibilityLabel("刷新预计时间")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(in: Capsule())
        .task(id: legKey) {
            await load()
        }
        .alert("无法打开地图", isPresented: Binding(get: { mapLinkHandler.alertMessage != nil }, set: { if !$0 { mapLinkHandler.alertMessage = nil } })) {
            Button("好", role: .cancel) { mapLinkHandler.alertMessage = nil }
        } message: {
            Text(mapLinkHandler.alertMessage ?? "")
        }
    }

    private func load() async {
        let store = CardLegStore(modelContext: modelContext)
        let stored = store.mode(for: legKey)
        if stored != mode { mode = stored }
        let cache = RouteCache(modelContext: modelContext)
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: stored, includeExpired: true) {
            estimate = cached
            fetchFailed = false
        } else {
            await fetch(force: false)
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
        } else {
            estimate = nil
            Task { await fetch(force: false) }
        }
    }

    private func refresh() async {
        await fetch(force: true)
    }

    private func fetch(force: Bool) async {
        isFetching = true
        defer { isFetching = false }
        let cache = RouteCache(modelContext: modelContext)
        if !force, let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true) {
            estimate = cached
            fetchFailed = false
            return
        }
        do {
            let result = try await AppleMapService.estimateRoute(origin: originPoint, destination: destinationPoint, mode: mode)
            try? cache.store(result, origin: originPoint, destination: destinationPoint, mode: mode)
            estimate = CachedRouteEstimate(estimate: result, cachedAt: .now)
            fetchFailed = false
        } catch {
            estimate = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true)
            fetchFailed = estimate == nil
        }
    }

    private static func distanceText(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f km", Double(meters) / 1000) : "\(meters) m"
    }

    private static func durationText(_ seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "约 \(minutes) 分"
    }
}
