import CoreLocation
import SwiftUI
import WeatherKit

/// 「今日」页展示的一条天气：对应一个地点聚类中心在当日（当地时间）的天气。
struct TodayWeatherEntry: Identifiable, Equatable, Sendable {
    let id: Int
    /// 距离聚类中心最近的 POI 名称；当日只有一个聚类时为 nil（不显示标签）。
    let label: String?
    let condition: String
    let symbolName: String
    let low: Int
    let high: Int
    /// 当前气温，仅所查日期即当地当日时展示。
    let current: Int?
}

/// 把当日 POI 按 2.5 公里半径聚类：所有位置都不超过半径时只保留一个聚类，
/// 天气取全部位置的地理中心；超过则贪心聚成多组，分别取各组地理中心。
enum WeatherClusterPlanner {
    /// 天气感知半径：2.5 公里内的天气变化可以忽略，合并为一个天气点。
    static let radiusMeters: CLLocationDistance = 2_500

    struct Cluster: Equatable, Sendable {
        var center: CLLocationCoordinate2D
        /// 距中心最近的输入位置名称，用于多聚类时的展示标签。
        var nearestName: String
        var memberCount: Int

        static func == (lhs: Cluster, rhs: Cluster) -> Bool {
            lhs.center.latitude == rhs.center.latitude
                && lhs.center.longitude == rhs.center.longitude
                && lhs.nearestName == rhs.nearestName
                && lhs.memberCount == rhs.memberCount
        }
    }

    static func clusters(for points: [(coordinate: CLLocationCoordinate2D, name: String)]) -> [Cluster] {
        guard !points.isEmpty else { return [] }
        if points.count == 1, let only = points.first {
            return [Cluster(center: only.coordinate, nearestName: only.name, memberCount: 1)]
        }
        let center = geographicCenter(of: points.map(\.coordinate))
        let farthest = points.map { distanceMeters(from: center, to: $0.coordinate) }.max() ?? 0
        if farthest <= radiusMeters {
            return [Cluster(center: center, nearestName: nearestName(to: center, in: points), memberCount: points.count)]
        }
        // 贪心聚类：按行程顺序把每个位置并入 2.5 公里内的第一个聚类，
        // 否则以它为起点新建聚类；聚类中心随成员加入更新为地理中心。
        var clusters: [(center: CLLocationCoordinate2D, members: [Int])] = []
        for (index, point) in points.enumerated() {
            if let existing = clusters.firstIndex(where: { distanceMeters(from: $0.center, to: point.coordinate) <= radiusMeters }) {
                clusters[existing].members.append(index)
                clusters[existing].center = geographicCenter(of: clusters[existing].members.map { points[$0].coordinate })
            } else {
                clusters.append((point.coordinate, [index]))
            }
        }
        return clusters.map {
            Cluster(center: $0.center, nearestName: nearestName(to: $0.center, in: points), memberCount: $0.members.count)
        }
    }

    /// 球面质心：把经纬度投影到单位球取平均，避免直接平均经度在跨
    /// 180° 经线时出错。
    static func geographicCenter(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coordinates.isEmpty else { return kCLLocationCoordinate2DInvalid }
        var x = 0.0
        var y = 0.0
        var z = 0.0
        for coordinate in coordinates {
            let latitude = coordinate.latitude * .pi / 180
            let longitude = coordinate.longitude * .pi / 180
            x += cos(latitude) * cos(longitude)
            y += cos(latitude) * sin(longitude)
            z += sin(latitude)
        }
        let count = Double(coordinates.count)
        x /= count
        y /= count
        z /= count
        let longitude = atan2(y, x) * 180 / .pi
        let latitude = atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func distanceMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    private static func nearestName(to center: CLLocationCoordinate2D, in points: [(coordinate: CLLocationCoordinate2D, name: String)]) -> String {
        points.min { distanceMeters(from: center, to: $0.coordinate) < distanceMeters(from: center, to: $1.coordinate) }?.name ?? ""
    }
}

/// 面向「今日」页的天气查询入口：先聚类，再用 Apple WeatherKit 按聚类中心
/// 查询逐日预报，按（坐标网格）做内存缓存，来回切换日期不重复请求。
actor TodayWeatherProvider {
    static let shared = TodayWeatherProvider()

    /// 一个坐标点缓存的天气：从当地“今天”起始的逐日预报 + 当前气温。
    struct LocationWeather: Equatable, Sendable {
        struct Day: Equatable, Sendable {
            let symbolName: String
            let condition: String
            let low: Int
            let high: Int
        }
        let days: [Day]
        let currentTemperature: Int
    }

    private struct CachedWeather: Sendable {
        let weather: LocationWeather
        let fetchedAt: Date
    }

    private var cache: [String: CachedWeather] = [:]
    private let cacheTTL: TimeInterval = 30 * 60

    /// - Parameters:
    ///   - date: 展示日的行程日期（yyyy-MM-dd）。
    ///   - today: 设备侧“今日”的同一格式字符串，用于定位逐日预报中的偏移。
    func entries(for points: [(coordinate: CLLocationCoordinate2D, name: String)], date: String, today: String) async -> [TodayWeatherEntry] {
        let clusters = WeatherClusterPlanner.clusters(for: points)
        // WeatherKit 逐日预报从当地“今天”开始：过去的日子与超出预报
        // 窗口（约 10 天）的日子没有数据，对应位置不显示天气。
        guard let offset = Self.dayOffset(from: today, to: date), offset >= 0 else { return [] }
        let showLabels = clusters.count > 1
        var entries: [TodayWeatherEntry] = []
        for (index, cluster) in clusters.enumerated() {
            guard let weather = await locationWeather(at: cluster.center), weather.days.indices.contains(offset) else { continue }
            let day = weather.days[offset]
            entries.append(TodayWeatherEntry(
                id: index,
                label: showLabels ? cluster.nearestName : nil,
                condition: day.condition,
                symbolName: day.symbolName,
                low: day.low,
                high: day.high,
                current: offset == 0 ? weather.currentTemperature : nil
            ))
        }
        return entries
    }

    /// 两个 yyyy-MM-dd 行程日之间的天数差（目标日减今日）；解析失败返回 nil。
    static func dayOffset(from today: String, to date: String) -> Int? {
        func parse(_ value: String) -> Date? {
            // DateFormatter 即使关闭宽松解析也会接受 "/" 分隔符，先用正则锁定格式。
            guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: value)
        }
        guard let from = parse(today), let to = parse(date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    private func locationWeather(at coordinate: CLLocationCoordinate2D) async -> LocationWeather? {
        // 两位小数网格（约 1.1 公里）合并亚公里级的聚类中心抖动。
        let key = "\((coordinate.latitude * 100).rounded() / 100),\((coordinate.longitude * 100).rounded() / 100)"
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.weather
        }
        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let (current, daily) = try await WeatherService.shared.weather(for: location, including: .current, .daily)
            let days = daily.forecast.map { day in
                LocationWeather.Day(
                    symbolName: day.symbolName,
                    condition: day.condition.description,
                    low: Int(day.lowTemperature.converted(to: .celsius).value.rounded()),
                    high: Int(day.highTemperature.converted(to: .celsius).value.rounded())
                )
            }
            let weather = LocationWeather(
                days: days,
                currentTemperature: Int(current.temperature.converted(to: .celsius).value.rounded())
            )
            cache[key] = CachedWeather(weather: weather, fetchedAt: Date())
            return weather
        } catch {
            // 天气是锦上添花：任何失败（离线、未授权、配额）都只表现为不显示。
            return nil
        }
    }
}

/// 今日地图顶部、日期切换器下方的天气胶囊行。单聚类时只显示温度；
/// 多聚类时每个胶囊附最近地点名标签，数量过多可横向滑动。
/// 末尾按 Apple 要求附 WeatherKit 数据来源标记（可点开法律页面）。
struct TodayWeatherRow: View {
    let entries: [TodayWeatherEntry]
    @State private var attribution: WeatherAttribution?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content }
                    .padding(.horizontal, 16)
            }
        }
        .task { attribution = try? await WeatherService.shared.attribution }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(entries) { entry in
            capsule(for: entry)
        }
        if let attribution {
            attributionLink(attribution)
        }
    }

    private func capsule(for entry: TodayWeatherEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.symbolName)
                .font(.caption)
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            if let label = entry.label, !label.isEmpty {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            HStack(spacing: 3) {
                if let current = entry.current {
                    Text(String(format: String(localized: "weather.currentTemp"), current))
                        .font(.caption.weight(.bold))
                }
                Text(String(format: String(localized: "weather.lowHigh"), entry.low, entry.high))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: entry))
    }

    private func attributionLink(_ attribution: WeatherAttribution) -> some View {
        Link(destination: attribution.legalPageURL) {
            AsyncImage(url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Text(attribution.serviceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 12)
            .fixedSize()
        }
        .accessibilityLabel(Text(String(format: String(localized: "weather.sourceA11y"), attribution.serviceName)))
    }

    private func accessibilityText(for entry: TodayWeatherEntry) -> String {
        var parts: [String] = []
        if let label = entry.label, !label.isEmpty { parts.append(label) }
        parts.append(entry.condition)
        if let current = entry.current { parts.append(String(format: String(localized: "weather.nowA11y"), current)) }
        parts.append(String(format: String(localized: "weather.rangeA11y"), entry.low, entry.high))
        return parts.joined(separator: String(localized: "lottery.contextSeparator"))
    }
}
