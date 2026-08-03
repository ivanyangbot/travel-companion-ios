import MapKit
import UIKit

/// Opens the system Apple Maps app for turn-by-turn navigation.
@MainActor
final class MapLinkHandler: ObservableObject {
    @Published var alertMessage: String?

    func openRoute(
        origin: RoutePoint,
        originName: String = "起点",
        destination: RoutePoint,
        destinationName: String = "终点",
        mode: RouteMode
    ) {
        // Unified Maps URLs document the exact source, destination and mode
        // contract. This opens the same route page users get in Apple Maps,
        // including its rendered path and route alternatives.
        var components = URLComponents(string: "https://maps.apple.com/directions")!
        components.queryItems = [
            URLQueryItem(name: "source", value: coordinate(origin)),
            URLQueryItem(name: "destination", value: coordinate(destination)),
            URLQueryItem(name: "mode", value: mode.mapsURLMode),
        ]
        guard let url = components.url else {
            alertMessage = "无法生成 Apple 地图导航链接。"
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened {
                self?.alertMessage = "无法打开 Apple 地图，请确认设备已安装并启用地图服务。"
            }
        }
    }

    private func coordinate(_ point: RoutePoint) -> String {
        "\(point.latitude),\(point.longitude)"
    }
}

private extension RouteMode {
    var mapsURLMode: String {
        switch self {
        case .walking: "walking"
        case .driving: "driving"
        case .transit: "transit"
        }
    }
}
