import SwiftUI
import SwiftData

struct RouteDestination: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String?
    let point: RoutePoint

    init(searchResult: PlaceSearchResult) {
        id = "apple-\(searchResult.id)"
        name = searchResult.name
        address = searchResult.address
        point = RoutePoint(latitude: searchResult.latitude, longitude: searchResult.longitude, cityCode: searchResult.cityCode)
    }

    init?(card: TravelCardSnapshot) {
        guard let place = card.place, let latitude = place.latitude, let longitude = place.longitude else { return nil }
        id = "card-\(card.id.uuidString)"
        name = place.name
        address = place.address
        point = RoutePoint(latitude: latitude, longitude: longitude, cityCode: place.cityCode)
    }
}

struct RouteSheet: View {
    let origin: PlaceSnapshot
    let suggestedDestinations: [RouteDestination]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var mapLinkHandler = MapLinkHandler()
    @State private var destination: RouteDestination?
    @State private var mode: RouteMode = .walking
    @State private var route: CachedRouteEstimate?
    @State private var isEstimating = false
    @State private var errorMessage: String?
    @State private var showsPlaceSearch = false

    init(origin: PlaceSnapshot, routeCards: [TravelCardSnapshot] = []) {
        self.origin = origin
        suggestedDestinations = routeCards.compactMap(RouteDestination.init(card:))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("起点") { placeRow(name: origin.name, address: origin.address) }
                Section("终点") {
                    if let destination {
                        placeRow(name: destination.name, address: destination.address)
                        Button("更换终点", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                    } else {
                        if !suggestedDestinations.isEmpty {
                            Text("推荐行程地点").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(suggestedDestinations.prefix(6)) { candidate in
                                Button {
                                    destination = candidate
                                    Task { await estimateIfPossible() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.name).foregroundStyle(.primary)
                                        if let address = candidate.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView("请选择终点", systemImage: "mappin.slash", description: Text("选择有坐标的地点后即可估算路线。"))
                        }
                        Button("搜索地点", systemImage: "magnifyingglass") { showsPlaceSearch = true }
                    }
                }
                Section("出行方式") {
                    Picker("方式", selection: $mode) {
                        ForEach(RouteMode.allCases) { item in Label(item.title, systemImage: item.systemImage).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in Task { await estimateIfPossible() } }
                }
                Section("路线估算") {
                    if isEstimating { HStack { ProgressView(); Text("正在查询 Apple 地图…") } }
                    if let route { estimateView(route) }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Button("刷新估算", systemImage: "arrow.clockwise") { Task { await fetchRoute(forceRefresh: true) } }
                        .disabled(destination == nil || isEstimating)
                }
                Section {
                    Button("在 Apple 地图中开始导航", systemImage: "arrow.triangle.turn.up.right.diamond") { openRoute() }
                        .disabled(destination == nil)
                } footer: {
                    Text("将把当前起点、终点和出行方式带入系统 Apple 地图。路线估算仅缓存 15 分钟。")
                }
            }
            .navigationTitle("路线")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showsPlaceSearch) {
                PlaceSearchView { selected in
                    destination = RouteDestination(searchResult: selected)
                    Task { await estimateIfPossible() }
                }
            }
            .alert("无法打开地图", isPresented: Binding(get: { mapLinkHandler.alertMessage != nil }, set: { if !$0 { mapLinkHandler.alertMessage = nil } })) {
                Button("好", role: .cancel) { mapLinkHandler.alertMessage = nil }
            } message: { Text(mapLinkHandler.alertMessage ?? "") }
        }
    }

    @ViewBuilder
    private func placeRow(name: String, address: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            if let address, !address.isEmpty { Text(address).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func estimateView(_ route: CachedRouteEstimate) -> some View {
        LabeledContent("距离", value: Self.distanceText(route.estimate.distanceMeters))
        LabeledContent("预计", value: Self.durationText(route.estimate.durationSeconds))
        LabeledContent("来源", value: route.estimate.source)
        LabeledContent("更新于", value: route.estimate.updatedAt.formatted(date: .omitted, time: .shortened))
        if !route.isFresh() { Text("显示的是过期缓存；请在网络恢复后刷新。") .font(.caption).foregroundStyle(.orange) }
    }

    private func estimateIfPossible() async {
        guard let destination, let originPoint = origin.point else { return }
        let cache = RouteCache(modelContext: modelContext)
        let destinationPoint = destination.point
        if let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode) {
            route = cached
            errorMessage = nil
            return
        }
        await fetchRoute(forceRefresh: false)
    }

    private func fetchRoute(forceRefresh: Bool) async {
        guard let destination, let originPoint = origin.point else {
            errorMessage = "起点或终点没有坐标，请先搜索地点。"
            return
        }
        let destinationPoint = destination.point
        let cache = RouteCache(modelContext: modelContext)
        if !forceRefresh, let cached = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode) {
            route = cached
            return
        }
        isEstimating = true
        errorMessage = nil
        do {
            let estimate = try await AppleMapService.estimateRoute(origin: originPoint, destination: destinationPoint, mode: mode)
            try cache.store(estimate, origin: originPoint, destination: destinationPoint, mode: mode)
            route = CachedRouteEstimate(estimate: estimate, cachedAt: .now)
        } catch {
            route = cache.cached(origin: originPoint, destination: destinationPoint, mode: mode, includeExpired: true)
            errorMessage = error.localizedDescription.isEmpty ? "无法获取 Apple 地图路线，请检查网络后重试。" : error.localizedDescription
        }
        isEstimating = false
    }

    private func openRoute() {
        guard let destination, let originPoint = origin.point else { return }
        mapLinkHandler.openRoute(
            origin: originPoint,
            originName: origin.name,
            destination: destination.point,
            destinationName: destination.name,
            mode: mode
        )
    }

    private static func distanceText(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f km", Double(meters) / 1000) : "\(meters) m"
    }

    private static func durationText(_ seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "约 \(minutes) 分"
    }
}

extension PlaceSnapshot {
    var point: RoutePoint? {
        guard let latitude, let longitude else { return nil }
        return RoutePoint(latitude: latitude, longitude: longitude, cityCode: cityCode)
    }
}
